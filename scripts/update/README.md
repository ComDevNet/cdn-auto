# Update

Update helpers for system and tool.

- [system.sh](./system.sh) — OS-level updates
- [tool.sh](./tool.sh) — update this repo/tooling

Inner workings

- system.sh wraps apt update/upgrade and may require sudo
- tool.sh pulls the latest changes from the repository and can refresh menus
