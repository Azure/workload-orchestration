# 1st Party Applications

This folder contains examples and scripts for Microsoft 1st party applications that can be deployed using Workload Orchestration.

## Purpose

Workload Orchestration enables the deployment and management of applications across edge and cloud environments. This folder serves as a central location for:

- **Deployment examples** — Sample configurations and templates for deploying 1st party applications.
- **Automation scripts** — PowerShell, Python, and shell scripts to automate deployment workflows.
- **Reference solutions** — End-to-end examples demonstrating best practices.

## Structure

Each 1st party application should have its own subfolder, for example:

```
1st party applications/
├── <application-name>/
│   ├── README.md              # Application-specific overview and instructions
│   ├── config/                # Configuration templates (YAML/JSON)
│   ├── scripts/               # Deployment/automation scripts
│   └── examples/              # Sample manifests or usage examples
```

## Contributing

When adding a new 1st party application example:

1. Create a dedicated subfolder named after the application.
2. Include a `README.md` describing the application and deployment steps.
3. Add configuration templates and scripts in their respective subfolders.
4. Document any prerequisites (e.g., required capabilities, dependencies).