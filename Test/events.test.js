import { createRequire } from 'node:module';
import { describe, it } from 'node:test';
import assert from 'node:assert';

const require = createRequire(import.meta.url);
const native = require(`${process.cwd()}/zig-out/lib/example.node`);

describe('Event Handling', () => {
    it('should handle connect event', (done) => {
        const client = native.createClient("127.0.0.1", 19132);
        assert(client, "Failed to create client");

        native.on(client, "connect", (msg) => {
            assert(msg !== undefined, "Message should be defined");
            native.destroyClient(client);
            done();
        });

        native.connect(client);
    });

    it('should handle disconnect event', (done) => {
        const client = native.createClient("127.0.0.1", 19132);
        assert(client, "Failed to create client");

        native.on(client, "disconnect", (msg) => {
            assert(msg !== undefined, "Message should be defined");
            done();
        });

        native.connect(client);
        setTimeout(() => {
            native.destroyClient(client);
        }, 100);
    });

    it('should handle multiple events', (done) => {
        const client = native.createClient("127.0.0.1", 19132);
        assert(client, "Failed to create client");

        let connectReceived = false;
        let disconnectReceived = false;

        native.on(client, "connect", () => {
            connectReceived = true;
            if (connectReceived && disconnectReceived) {
                done();
            }
        });

        native.on(client, "disconnect", () => {
            disconnectReceived = true;
            if (connectReceived && disconnectReceived) {
                done();
            }
        });

        native.connect(client);
        setTimeout(() => {
            native.destroyClient(client);
        }, 100);
    });
}); 