export declare class Client {
    private constructor();
}

export declare class zigraknet {
    /**
     * Creates a new RakNet client instance
     * @param host The host address to connect to
     * @param port The port to connect to
     * @returns A new Client instance or null if creation failed
     */
    createClient(host: string, port: number): Client | null;

    /**
     * Connects the client to the server
     * @param client The client instance to connect
     * @returns True if connection was successful, false otherwise
     */
    connect(client: Client): boolean;

    /**
     * Checks if the client is connected
     * @param client The client instance to check
     * @returns True if connected, false otherwise
     */
    isConnected(client: Client): boolean;

    /**
     * Sends data through the client
     * @param client The client instance to send data through
     * @param data The data buffer to send
     * @returns True if send was successful, false otherwise
     */
    sendData(client: Client, data: Buffer): boolean;

    /**
     * Destroys a client instance and frees its resources
     * @param client The client instance to destroy
     */
    destroyClient(client: Client): void;

    /**
     * Simple addition function (test function)
     * @param a First number
     * @param b Second number
     * @returns Sum of a and b
     */
    add(a: number, b: number): number;
} 