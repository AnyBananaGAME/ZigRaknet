import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
/**
 * @type {import('./index').zigraknet}
 */
const native = require(`${process.cwd()}/zig-out/lib/example.node`)

console.log('1 + 22 =', native.add(1, 22));

try {
    const client = native.createClient("127.0.0.1", 19132);
    if (!client) {
        throw new Error("Failed to create client");
    }
    
    console.log('Connecting...', native.connect(client));
    console.log('Is connected:', native.isConnected(client));
    
    // native.sendData(client, Buffer.from("Once upon a time, there was a cat. The cat was a cat. And liked to eat mice. The end."));
    // Keep the process alive
    setInterval(() => {
        console.log('Is connected:', native.isConnected(client));
    }, 1000);
    
    // Cleanup on exit
    process.on('SIGINT', () => {
        native.destroyClient(client);
        process.exit();
    });
} catch (error) {
    console.error('Error:', error);
    process.exit(1);
}