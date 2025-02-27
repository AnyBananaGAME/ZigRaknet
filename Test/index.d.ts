export declare class Client {
    private constructor();
    debug: boolean;
}

/**
 * Available event types that can be listened to
 */
export type RakNetEventType = 
    | 'connect'        // Emitted when successfully connected
    | 'disconnect'     // Emitted when disconnected
    | 'drop_frameset'  // Emitted when a frameset is dropped due to out-of-order delivery
    | 'encapsulated'   // Emitted when encapsulated data is received
    | 'message';       // Emitted for raw socket messages

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
     * Gets the debug mode state
     * @param client The client instance to check
     * @returns True if debug mode is enabled, false otherwise
     */
    getDebug(client: Client): boolean;

    /**
     * Sets the debug mode state
     * @param client The client instance to modify
     * @param value The debug mode state to set
     * @returns True if successful, false otherwise
     */
    setDebug(client: Client, value: boolean): boolean;

    /**
     * Sends data through the client
     * @param client The client instance to send data through
     * @param data The data buffer to send
     * @returns True if send was successful, false otherwise
     */
    sendData(client: Client, data: Buffer): boolean;

    /**
     * Registers an event listener for the specified event
     * @param client The client instance to listen on
     * @param event The event type to listen for
     * @param callback The callback function to handle the event
     * @returns True if listener was registered successfully, false otherwise
     */
    on(client: Client, event: RakNetEventType, callback: (msg: string) => void): boolean;

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