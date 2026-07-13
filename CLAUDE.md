# CLAUDE.md

## Project Structure

This is an OpenShift Virtualization POC project with 21 numbered lab directories.

### Language Structure (en / ko)

`en/` and `ko/` are each **fully self-contained** and independently runnable:

```
en/                              ← English (fully self-contained)
├── setup.sh
├── poc.sh
├── check-features.sh
├── env.conf.example
├── utils/common.sh
├── operators/                   ← Operator installation guides
├── sample/                      ← Sample YAML files
├── 01-template/ ~ 21-upgrade/  ← All lab directories
└── EXECUTION-ORDER.md, RESET-vs-CLEANUP.md

ko/                              ← Korean (fully self-contained)
├── setup.sh
├── poc.sh
├── check-features.sh
├── env.conf.example
├── utils/common.sh
├── operators/
├── sample/
├── 01-template/ ~ 21-upgrade/
└── EXECUTION-ORDER.md, RESET-vs-CLEANUP.md
```

Root level keeps: `CLAUDE.md`, `README.md`, `.gitignore`, `download.sh`, `package.sh`, `AIRGAP.md`.

### Conventions

- All `.sh` scripts and `.md` docs in `en/` must be written in **English**.
- All `.sh` scripts and `.md` docs in `ko/` must be written in **Korean**.
- Script logic and YAML templates are identical between en/ko — only user-facing strings (echo messages, comments, documentation) differ.
- When creating or modifying a lab, always update **both** `en/` and `ko/` versions.
- `env.conf` is generated per language directory by running `setup.sh` inside it.
