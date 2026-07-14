// config.ts — Configuration for toscanini-mcp

export interface Config {
  port: number;
  toscaniniUrl: string;
}

export function loadConfig(): Config {
  return {
    port: parseInt(process.env.PORT || "8006", 10),
    toscaniniUrl: process.env.TOSCANINI_URL || "http://localhost:8080/api/orchestrator",
  };
}
