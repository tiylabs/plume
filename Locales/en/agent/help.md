Plume lets an AI agent on this Mac work with your notes through a small helper inside the app.

1. Choose what the agent may do: "Read only" lets it search and read notes; "Read and write" also
   lets it create notes and change parts of them.
2. If your agent supports local MCP servers, press Copy next to MCP configuration and paste it
   into the agent's MCP settings (for many agents, an "mcpServers" section). Restart the agent.
3. If your agent runs shell commands instead, use the command-line helper with the credential in
   PLUME_CLI_TOKEN, for example: plume-cli notes search --query "project".

The agent can search and read notes, read your writing preferences and templates, create notes and
change parts of a note. It cannot delete notes, move your notes folder, change settings or run Git.

While you are typing in a note, changes to that note are refused until you stop; the agent is told
to try again or create a new note. Every write is listed under Recent writes, where a change can be
restored.

If you move Plume.app, copy the configuration again. After updating Plume, restart the agent.
Limits: 100 notes per page, 1 MB per note, 32 changes per request, 30 writes per minute.
