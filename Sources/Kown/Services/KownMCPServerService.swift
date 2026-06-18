import Foundation

@MainActor
enum KownMCPServerService {
    private static var installDir: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Kown/MCPServer", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var scriptURL: URL {
        installDir.appendingPathComponent("kown-mcp-server.js")
    }

    static var dataDir: URL { Platform.syncedDataDir }

    static func installOrUpdate() throws -> URL {
        let script = serverScript
        try script.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber],
                                              ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    static func claudeConfigSnippet() -> String {
        """
        {
          "mcpServers": {
            "kown": {
              "command": "\(scriptURL.path)",
              "env": {
                "KOWN_DATA_DIR": "\(dataDir.path)"
              }
            }
          }
        }
        """
    }

    static func cursorConfigSnippet() -> String {
        """
        {
          "kown": {
            "command": "\(scriptURL.path)",
            "env": {
              "KOWN_DATA_DIR": "\(dataDir.path)"
            }
          }
        }
        """
    }

    private static var serverScript: String {
        #"""
        #!/usr/bin/env node
        const fs = require('fs');
        const path = require('path');
        const os = require('os');

        const dataDir = process.env.KOWN_DATA_DIR || path.join(os.homedir(), '.kown');
        const convDir = path.join(dataDir, 'conversations');

        function send(id, result) {
          if (id === undefined || id === null) return;
          process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n');
        }

        function sendError(id, message, code = -32000) {
          if (id === undefined || id === null) return;
          process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n');
        }

        function readJSON(file, fallback) {
          try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
        }

        function conversations(limit = 100) {
          let files = [];
          try {
            files = fs.readdirSync(convDir)
              .filter(f => f.endsWith('.json'))
              .map(f => {
                const p = path.join(convDir, f);
                return { path: p, mtime: fs.statSync(p).mtimeMs };
              })
              .sort((a, b) => b.mtime - a.mtime)
              .slice(0, limit);
          } catch { return []; }
          return files.map(f => readJSON(f.path, null)).filter(Boolean);
        }

        function memories() {
          return readJSON(path.join(dataDir, 'memories.json'), []);
        }

        function convText(c) {
          const parts = [c.title || '', c.contextSummary || ''];
          for (const t of (c.turns || [])) {
            parts.push(t.prompt || '');
            for (const value of Object.values(t.responses || {})) parts.push(value || '');
            parts.push(t.chairSummary || '', t.summaryText || '');
          }
          return parts.join('\n');
        }

        function compactConversation(c) {
          const turns = (c.turns || []).slice(-8).map((t, i) => {
            const answers = Object.values(t.responses || {}).filter(Boolean).slice(0, 3).join('\n---\n');
            return `## Turn ${i + 1}\nUser: ${t.prompt || ''}\n\nAssistant:\n${answers || t.chairSummary || ''}`;
          }).join('\n\n');
          return `# ${c.title || c.id}\n\nID: ${c.id}\nUpdated: ${c.updatedAt || ''}\nMode: ${c.mode || ''}\n\n${turns}`;
        }

        function searchConversations(args) {
          const query = String(args.query || '').toLowerCase();
          const limit = Math.min(Number(args.limit || 8), 20);
          const hits = conversations(200)
            .map(c => ({ c, text: convText(c) }))
            .filter(x => !query || x.text.toLowerCase().includes(query))
            .slice(0, limit)
            .map(x => `- ${x.c.title || '(untitled)'} (${x.c.id})\n  ${x.text.slice(0, 360).replace(/\s+/g, ' ')}`);
          return hits.length ? hits.join('\n') : 'No matching conversations.';
        }

        function getConversation(args) {
          const id = String(args.id || '');
          const found = conversations(300).find(c => c.id === id || String(c.id || '').startsWith(id));
          return found ? compactConversation(found) : 'Conversation not found.';
        }

        function searchMemories(args) {
          const query = String(args.query || '').toLowerCase();
          const limit = Math.min(Number(args.limit || 12), 30);
          const hits = memories()
            .filter(m => !query || String(m.text || '').toLowerCase().includes(query))
            .slice(0, limit)
            .map(m => `- ${m.text} (${m.id})`);
          return hits.length ? hits.join('\n') : 'No matching memories.';
        }

        const tools = [
          {
            name: 'kown_search_conversations',
            description: 'Search recent Kown conversations by keyword.',
            inputSchema: { type: 'object', properties: { query: { type: 'string' }, limit: { type: 'number' } }, required: ['query'] }
          },
          {
            name: 'kown_get_conversation',
            description: 'Read one Kown conversation by id prefix.',
            inputSchema: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] }
          },
          {
            name: 'kown_search_memories',
            description: 'Search Kown long-term memories.',
            inputSchema: { type: 'object', properties: { query: { type: 'string' }, limit: { type: 'number' } }, required: ['query'] }
          }
        ];

        function callTool(name, args) {
          if (name === 'kown_search_conversations') return searchConversations(args || {});
          if (name === 'kown_get_conversation') return getConversation(args || {});
          if (name === 'kown_search_memories') return searchMemories(args || {});
          return `Unknown tool: ${name}`;
        }

        function handle(msg) {
          const { id, method, params } = msg;
          try {
            if (method === 'initialize') {
              send(id, { protocolVersion: '2024-11-05', capabilities: { tools: {}, resources: {} }, serverInfo: { name: 'Kown MCP', version: '0.1.0' } });
            } else if (method === 'notifications/initialized') {
              return;
            } else if (method === 'tools/list') {
              send(id, { tools });
            } else if (method === 'tools/call') {
              const text = callTool(params && params.name, params && params.arguments);
              send(id, { content: [{ type: 'text', text }], isError: false });
            } else if (method === 'resources/list') {
              const resources = conversations(20).map(c => ({ uri: `kown://conversation/${c.id}`, name: c.title || c.id, mimeType: 'text/markdown' }));
              send(id, { resources });
            } else if (method === 'resources/read') {
              const uri = String(params && params.uri || '');
              const idPart = uri.split('/').pop();
              send(id, { contents: [{ uri, mimeType: 'text/markdown', text: getConversation({ id: idPart }) }] });
            } else {
              sendError(id, `Unsupported method: ${method}`, -32601);
            }
          } catch (err) {
            sendError(id, err && err.message ? err.message : String(err));
          }
        }

        let buffer = '';
        process.stdin.on('data', chunk => {
          buffer += chunk.toString('utf8');
          let idx;
          while ((idx = buffer.indexOf('\n')) >= 0) {
            const line = buffer.slice(0, idx).trim();
            buffer = buffer.slice(idx + 1);
            if (!line) continue;
            try { handle(JSON.parse(line)); } catch (err) { sendError(null, String(err)); }
          }
        });
        """#
    }
}
