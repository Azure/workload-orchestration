import logging
import azure.functions as func
import httpx
from azure.identity import DefaultAzureCredential

from namespace_validator import (
    get_effective_namespace,
    collect_referenced_namespaces,
    ARM_BASE,
)

app = func.FunctionApp()


@app.event_grid_trigger(arg_name="event")
async def SolutionValidator(event: func.EventGridEvent):
    data = event.get_json()

    solution_version_id = data.get("solutionVersionId")
    target_id = data.get("targetId")
    external_validation_id = data.get("externalValidationId")
    callback_url = data.get("callbackUrl")
    api_version = data.get("apiVersion")

    logging.info("Validating %s (extId=%s)", solution_version_id, external_validation_id)

    if not (solution_version_id and target_id and callback_url and api_version):
        logging.error("Event is missing required fields; aborting.")
        return

    token = _get_arm_token()
    if not token:
        logging.error("Could not acquire ARM token; aborting.")
        return

    try:
        async with httpx.AsyncClient(timeout=60) as client:
            target = await _arm_get(client, target_id, api_version, token)
            solution_version = await _arm_get(client, solution_version_id, api_version, token)

        effective_ns = get_effective_namespace(target, solution_version)
        logging.info("Effective namespace (solutionScope) = %s", effective_ns)

        referenced = collect_referenced_namespaces(solution_version, effective_ns)
        bad = sorted({ns for ns in referenced if ns and ns.lower() != effective_ns})

        if bad:
            validation_status = "Invalid"
            error_details = {
                "code": "NamespaceScopeMismatch",
                "message": (f"Chart references namespace(s) {bad}; "
                            f"solutionScope is '{effective_ns}'."),
                "target": solution_version_id,
                "additionalInfo": [
                    {"type": "NamespaceViolation",
                     "info": {"level": "Error", "expected": effective_ns, "found": bad}}
                ],
            }
        else:
            validation_status = "Valid"
            error_details = None

    except Exception as ex:  # fail-closed: reject on validator error (see design doc, open question 2)
        logging.exception("Validation failed with an unexpected error.")
        validation_status = "Invalid"
        error_details = {
            "code": "ValidationExecutionError",
            "message": f"External validator failed to evaluate the chart: {ex}",
            "target": solution_version_id,
        }

    _log_decision(solution_version_id, external_validation_id, validation_status, error_details)

    # COMMENT FOLLOWING CALL FOR TEST MODE: do not post back to ARM. We confirm the flow by monitoring the
    # Function App logs (see _log_decision above). Re-enable for production use.
    await _post_result(callback_url, token, solution_version_id,
                       external_validation_id, validation_status, error_details)


def _log_decision(solution_version_id, external_validation_id, validation_status, error_details):
    """Log the validation outcome so the flow can be verified from Function App logs."""
    if validation_status == "Valid":
        logging.info(
            "VALIDATION RESULT = SUCCESS | ACCEPTED | solutionVersionId=%s | extId=%s",
            solution_version_id, external_validation_id,
        )
    else:
        logging.warning(
            "VALIDATION RESULT = REJECTED | solutionVersionId=%s | extId=%s | details=%s",
            solution_version_id, external_validation_id, error_details,
        )


def _get_arm_token():
    try:
        credential = DefaultAzureCredential()
        return credential.get_token(f"{ARM_BASE}/.default").token
    except Exception:
        logging.exception("Token acquisition failed.")
        return None


async def _arm_get(client: httpx.AsyncClient, resource_id: str, api_version: str, token: str) -> dict:
    url = f"{ARM_BASE}/{resource_id.lstrip('/')}?api-version={api_version}"
    resp = await client.get(url, headers={"Authorization": f"Bearer {token}"})
    resp.raise_for_status()
    return resp.json()


async def _post_result(callback_url, token, solution_version_id,
                       external_validation_id, validation_status, error_details):
    body = {
        "solutionVersionId": solution_version_id,
        "externalValidationId": external_validation_id,
        "validationStatus": validation_status,
        "errorDetails": error_details,
    }
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            callback_url,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            json=body,
        )
        if resp.status_code in (200, 201, 202):
            logging.info("Posted validation result: %s", validation_status)
        else:
            logging.error("Callback failed. Status=%s Body=%s", resp.status_code, resp.text)
