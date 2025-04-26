# Docker Compose Migration Plan

## Planned Directory Structure Change
- Move from: `hosts/misc/docker-compose/`
- To: `hosts/misc/`

## Required Changes

### File References to Update
1. **build/preseed.cfg** (line 96)
   - Update directory path for traefik setup

2. **README.md** (multiple locations)
   - Update approximately 12 references to:
     - Authelia configuration paths
     - Traefik configuration paths
     - DNS setup script paths
     - Wireguard configuration paths
     - Example commands

3. **.gitignore**
   - Update paths for:
     - traefik/acme.json
     - wireguard configuration files

### File Operations
- Preserve all directory structures when moving files
- Update up.sh script references
- Handle the removed upprod.sh script

## Implementation Approach
When ready to migrate, all files should be moved while maintaining their relative structure, followed by path updates in all reference locations listed above.