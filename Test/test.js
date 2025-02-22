import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
/**
 * @type {import('./index').zigraknet}
 */
const native = require(`${process.cwd()}/zig-out/lib/example.node`)


try {
    const coTime = Date.now();
    const interval = setInterval(() => {
        if(native.isConnected(client)) {
            clearInterval(interval);
            console.log('Via NAPI Connected in', Date.now() - coTime, 'ms');
        }
    }, 1);

    const client = native.createClient("127.0.0.1", 19132);
    if (!client) {
        throw new Error("Failed to create client");
    }
    
    console.log('Connecting...', native.connect(client));
    // console.log('Is connected:', native.isConnected(client));
    // native.sendData(client, Buffer.from("Once upon a time, there was a cat. The cat was a cat. And liked to eat mice. The end."));
    // Keep the process alive
   
    
    // Cleanup on exit
    process.on('SIGINT', () => {
        native.destroyClient(client);
        process.exit();
    });
} catch (error) {
    console.error('Error:', error);
    process.exit(1);
}