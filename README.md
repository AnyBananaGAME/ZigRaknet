# Zig RakNet

A simple and easy to use RakNet implementation in Zig.

## Installation

```bash
git clone https://github.com/AnyBananaGAME/ZigRaknet.git
cd ZigRaknet
zig build
node Test/test.js
```

## Usage in Zig

```ts
const Client = @import("./src/client/client.zig").Client;
const std = @import("std");

var client = try Client.init("127.0.0.1", 19132);
defer client.deinit();
try client.connect();

while (true) {
    std.time.sleep(50 * std.time.ns_per_ms);
    try client.tick();
}
```

## Usage in Node.js

```ts
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)

// If you have the .d.ts you can do
/**
 * @type {import('./index').zigraknet}
 */
const native = require(`${process.cwd()}/zig-out/lib/example.node`)

const client = native.createClient("127.0.0.1", 19132);
if (!client) {
    throw new Error("Failed to create client");
}

native.connect(client);
setInterval(() => {
    console.log('Is connected:', native.isConnected(client));
}, 1000);
```
