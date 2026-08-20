# Applications

This folder contains examples and scripts for applications that can be deployed using Workload Orchestration.

## Purpose

Workload Orchestration enables the deployment and management of applications across edge and cloud environments. This folder serves as a central location for:

- **Deployment examples** — Sample configurations and templates for deploying applications.
- **Automation scripts** — PowerShell, Python, and shell scripts to automate deployment workflows.
- **Reference solutions** — End-to-end examples demonstrating best practices.

## Structure

Each application should have its own subfolder, for example:

```
applications/
├── <application-name>/
│   ├── README.md              # Application-specific overview and instructions
│   ├── config/                # Configuration templates (YAML/JSON)
│   ├── scripts/               # Deployment/automation scripts
│   └── examples/              # Sample manifests or usage examples
```

## Contributing

When adding a new application example:

1. Create a dedicated subfolder named after the application.
2. Include a `README.md` describing the application and deployment steps.
3. Add configuration templates and scripts in their respective subfolders.
4. Document any prerequisites (e.g., required capabilities, dependencies).