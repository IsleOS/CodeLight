/**
 * In-memory store for Claude Code capability snapshots (slash commands, skills,
 * MCP servers) uploaded by MioIsland. Never persisted — each device keeps its
 * latest snapshot, overwritten on every upload.
 */

export interface CapabilityItem {
    name: string;
    description: string;
    source: string;
}

export interface CapabilitySnapshot {
    builtinCommands: CapabilityItem[];
    userCommands: CapabilityItem[];
    pluginCommands: CapabilityItem[];
    projectCommands: CapabilityItem[];
    userSkills: CapabilityItem[];
    pluginSkills: CapabilityItem[];
    projectSkills: CapabilityItem[];
    mcpServers: CapabilityItem[];
    projectPath: string | null;
    scannedAt: number;
}

const snapshots = new Map<string, CapabilitySnapshot>();

export function putCapabilities(deviceId: string, snapshot: CapabilitySnapshot) {
    snapshots.set(deviceId, snapshot);
}

export function getCapabilities(deviceId: string): CapabilitySnapshot | undefined {
    return snapshots.get(deviceId);
}
