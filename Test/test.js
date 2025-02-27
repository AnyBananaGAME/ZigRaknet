import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const native = require(`${process.cwd()}/zig-out/lib/example.node`)

console.log('Starting RakNet client...')
const client = native.createClient("127.0.0.1", 19132)
if (!client) {
    console.error("Failed to create client")
    process.exit(1)
}

// Enable debug mode
// if (!native.setDebug(client, true)) {
    // console.error("Failed to enable debug mode")
    // process.exit(1)
// }

// Handle encapsulated data
console.log("Registering encapsulated event handler")
const success = native.on(client, "encapsulated", (data) => {
    try {
        if(data[0] !== 254) {
            console.log("Received non-encapsulated packet")
            console.log(data)
            return
        }
        console.log("\nEncapsulated Message Details:");
        console.log("- Raw Buffer:", data);
        console.log("- Buffer Length:", data.length);
        console.log("- First Byte (Packet ID):", data[0]);
        console.log("- Raw bytes:", Array.from(data));
        console.log(); // Empty line for readability
    } catch (err) {
        console.error("Error processing encapsulated message:", err);
    }
});

if (!success) {
    console.error("Failed to register encapsulated event handler")
    process.exit(1)
}

// Log connection events
native.on(client, "connect", () => {
    console.log("Connected to server")
})

native.on(client, "disconnect", () => {
    console.log("Disconnected from server")
    process.exit(0)
})

// Connect to server
console.log("Connecting to server...")
if (!native.connect(client)) {
    console.error("Failed to connect to server")
    process.exit(1)
}

// Keep the process alive
const interval = setInterval(() => {
    if (!native.isConnected(client)) {
        console.log("Client disconnected, cleaning up")
        clearInterval(interval)
        native.destroyClient(client)
        process.exit(0)
    }
}, 1000)

// Cleanup on exit
process.on('SIGINT', () => {
    console.log("Cleaning up...")
    clearInterval(interval)
    native.destroyClient(client)
    process.exit(0)
})