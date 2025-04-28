# ZNET 🚀

[![Language](https://img.shields.io/badge/language-Zig-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-Apache-blue.svg)](LICENSE)

A fast, reliable, and easy-to-use RakNet implementation in Zig. Perfect for game networking, especially for Minecraft Bedrock Edition clients.

## ✨ Features

- 🔥 Zig implementation - no external dependencies
- 🚀 High-performance networking with non-blocking I/O
- 🛡️ Reliable and ordered packet delivery
- 🎮 Minecraft Bedrock Edition compatible

## 🚀 Installation

```bash
git clone https://github.com/AnyBananaGAME/ZigRaknet.git
cd ZigRaknet
zig build
```

## 📚 Usage

Here's a simple example of how to create a client and connect to a RakNet server:

```zig
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

## 🤝 Contributing

Contributions are welcome! Feel free to:
- Report bugs
- Suggest new features
- Submit pull requests

## 📝 License

This project is licensed under the Apache-2.0 License.

## 💖 Credits

- Thanks to a user on Discord (akashic_records_of_the_abyss) for the name suggestion
- Inspired by the RakNet protocol
