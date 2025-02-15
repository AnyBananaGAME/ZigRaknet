# Zig RakNet

A simple and easy to use RakNet implementation in Zig.

## Installation

```bash
git clone https://github.com/AnyBananaGAME/ZigRaknet.git
cd ZigRaknet
zig build
node Test/test.js
```

## Usage

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
