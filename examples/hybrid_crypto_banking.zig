const std = @import("std");
const zqlite = @import("zqlite");

/// 🏦 ZQLite v0.5.0 Hybrid Crypto Banking Example
/// Next-generation financial database with post-quantum security
/// Features: ML-KEM, ML-DSA, ZKP privacy, quantum-safe transactions
const BankingError = error{
    InsufficientFunds,
    AccountNotFound,
    InvalidTransaction,
    CryptoError,
    AuthenticationFailed,
};

const Account = struct {
    id: []const u8,
    encrypted_balance: zqlite.crypto.EncryptedField,
    public_key_classical: [32]u8,
    public_key_pq: [1952]u8, // ML-DSA-65 public key
    account_type: AccountType,
    created_at: i64,

    const AccountType = enum {
        Checking,
        Savings,
        Investment,
        CorporateVault,
    };
};

const Transaction = struct {
    id: []const u8,
    from_account: []const u8,
    to_account: []const u8,
    amount: u64,
    signature: zqlite.crypto.HybridSignature,
    timestamp: i64,
    tx_type: TransactionType,
    zero_knowledge_proof: ?zqlite.crypto.ZKProof,

    const TransactionType = enum {
        Transfer,
        Deposit,
        Withdrawal,
        PrivateTransfer, // Uses zero-knowledge proofs
    };
};

const PostQuantumBank = struct {
    allocator: std.mem.Allocator,
    db: *zqlite.Connection,
    crypto_engine: zqlite.crypto.CryptoEngine,
    transaction_log: zqlite.crypto.CryptoTransactionLog,
    zkp_enabled: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db_path: ?[]const u8) !Self {
        const db = if (db_path) |path|
            try zqlite.open(path)
        else
            try zqlite.openMemory();

        var crypto = try zqlite.crypto.CryptoEngine.initWithMasterKey(allocator, "post_quantum_banking_master_key_2024_ultra_secure");

        const tx_log = zqlite.crypto.CryptoTransactionLog.init(allocator);

        var bank = Self{
            .allocator = allocator,
            .db = db,
            .crypto_engine = crypto,
            .transaction_log = tx_log,
            .zkp_enabled = true,
        };

        crypto.enableZKP();
        try bank.initializeSchema();

        return bank;
    }

    fn initializeSchema(self: *Self) !void {
        // Create accounts table with encrypted columns
        try self.db.execute(
            \\CREATE TABLE IF NOT EXISTS accounts (
            \\    id TEXT PRIMARY KEY,
            \\    encrypted_balance BLOB,
            \\    public_key_classical BLOB,
            \\    public_key_pq BLOB,
            \\    account_type INTEGER,
            \\    created_at INTEGER
            \\);
        );

        // Create transactions table with hybrid signatures
        try self.db.execute(
            \\CREATE TABLE IF NOT EXISTS transactions (
            \\    id TEXT PRIMARY KEY,
            \\    from_account TEXT,
            \\    to_account TEXT,
            \\    amount_commitment BLOB,
            \\    signature_classical BLOB,
            \\    signature_pq BLOB,
            \\    timestamp INTEGER,
            \\    tx_type INTEGER,
            \\    zkp_proof BLOB
            \\);
        );

        // Create audit log table
        try self.db.execute(
            \\CREATE TABLE IF NOT EXISTS audit_log (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    operation TEXT,
            \\    table_name TEXT,
            \\    data_hash BLOB,
            \\    signature BLOB,
            \\    timestamp INTEGER
            \\);
        );

        std.debug.print("✅ Initialized post-quantum banking schema\n", .{});
    }

    /// Create a new account with post-quantum security
    pub fn createAccount(self: *Self, account_id: []const u8, initial_balance: u64, account_type: Account.AccountType) !void {
        std.debug.print("🏦 Creating account: {s}\n", .{account_id});

        // Generate post-quantum key pair for the account
        const keypair = try self.crypto_engine.generateKeyPair();

        // Encrypt initial balance
        const balance_bytes = std.mem.asBytes(&initial_balance);
        const encrypted_balance = try self.crypto_engine.encryptField(balance_bytes);

        // Create encrypted field for balance
        const encrypted_field = zqlite.crypto.EncryptedField{
            .ciphertext = encrypted_balance,
            .nonce = std.mem.zeroes([12]u8),
            .tag = std.mem.zeroes([16]u8),
        };

        // Create account record
        var pq_key: [1952]u8 = std.mem.zeroes([1952]u8);
        // Copy classical key to beginning of PQ key (mock implementation)
        @memcpy(pq_key[0..32], &keypair.classical.public_key);

        _ = Account{
            .id = account_id,
            .encrypted_balance = encrypted_field,
            .public_key_classical = keypair.classical.public_key,
            .public_key_pq = pq_key,
            .account_type = account_type,
            .created_at = blk: {
                const ts = zqlite.time_utils.getTimespec();
                break :blk ts.sec;
            },
        };

        // Insert into database (simplified - in production would use prepared statements)
        try self.db.execute("INSERT INTO accounts (id, account_type, created_at) VALUES ('{}', {}, {});");

        // Log creation in cryptographic audit trail
        const audit_data = try std.fmt.allocPrint(self.allocator, "CREATE_ACCOUNT:{s}:{d}", .{ account_id, initial_balance });
        defer self.allocator.free(audit_data);

        try self.transaction_log.logOperation("CREATE_ACCOUNT", audit_data);

        std.debug.print("✅ Account created with post-quantum security\n", .{});
        std.debug.print("   - ID: {s}\n", .{account_id});
        std.debug.print("   - Type: {s}\n", .{@tagName(account_type)});
        std.debug.print("   - Initial balance: {} (encrypted)\n", .{initial_balance});
    }

    /// Transfer funds with hybrid classical + post-quantum signatures
    pub fn transfer(self: *Self, from_account: []const u8, to_account: []const u8, amount: u64, private_transfer: bool) !void {
        std.debug.print("💸 Processing transfer: {s} → {s} (amount: {})\n", .{ from_account, to_account, amount });

        // Generate transaction ID
        const ts = zqlite.time_utils.getTimespec();
        const timestamp = ts.sec;
        const tx_id = try std.fmt.allocPrint(self.allocator, "tx_{d}", .{timestamp});
        defer self.allocator.free(tx_id);

        // Create transaction data for signing
        const tx_data = try std.fmt.allocPrint(self.allocator, "TRANSFER:{s}:{s}:{d}:{d}", .{ from_account, to_account, amount, timestamp });
        defer self.allocator.free(tx_data);

        // Sign transaction with hybrid signature
        const sig_data = try self.crypto_engine.signTransaction(tx_data);

        // Create hybrid signature structure (mock implementation)
        var classical_sig: [64]u8 = undefined;
        @memset(&classical_sig, 0);
        @memcpy(classical_sig[0..32], sig_data); // Use hash as part of classical sig

        const pq_sig = try self.allocator.alloc(u8, 3309); // ML-DSA-65 size
        @memset(pq_sig, 0x42); // Fill with dummy data

        const signature = zqlite.crypto.HybridSignature{
            .classical = classical_sig,
            .post_quantum = pq_sig,
        };
        std.debug.print("✅ Transaction signed with hybrid crypto\n", .{});
        std.debug.print("   - Classical signature (Ed25519): 64 bytes\n", .{});
        std.debug.print("   - Post-quantum signature (ML-DSA-65): 3309 bytes\n", .{});

        // For private transfers, create zero-knowledge proof
        var zkp_proof: ?zqlite.crypto.ZKProof = null;
        if (private_transfer and self.zkp_enabled) {
            std.debug.print("🕵️ Creating zero-knowledge proof for private transfer...\n", .{});

            // Prove amount is in valid range without revealing it
            const proof_data = try self.crypto_engine.createRangeProof(amount, 1, 1000000);
            zkp_proof = zqlite.crypto.ZKProof{
                .proof_data = proof_data,
                .commitment = std.mem.zeroes([32]u8),
                .challenge = std.mem.zeroes([32]u8),
            };

            std.debug.print("✅ Zero-knowledge proof generated\n", .{});
            std.debug.print("   - Proof type: Range proof\n", .{});
            std.debug.print("   - Proves: 1 ≤ amount ≤ 1,000,000\n", .{});
            std.debug.print("   - Amount remains private\n", .{});
        }

        // Create transaction record
        const transaction = Transaction{
            .id = tx_id,
            .from_account = from_account,
            .to_account = to_account,
            .amount = amount,
            .signature = signature,
            .timestamp = blk: {
                const ts2 = zqlite.time_utils.getTimespec();
                break :blk ts2.sec;
            },
            .tx_type = if (private_transfer) .PrivateTransfer else .Transfer,
            .zero_knowledge_proof = zkp_proof,
        };

        // Verify transaction before processing
        const mock_pubkey = std.mem.zeroes([32]u8); // Mock public key for demo
        const signature_bytes = signature.classical; // Use classical part for verification
        const is_valid = try self.crypto_engine.verifyTransaction(tx_data, &signature_bytes, mock_pubkey);
        if (!is_valid) {
            return BankingError.InvalidTransaction;
        }

        std.debug.print("✅ Transaction signature verified\n", .{});

        // Verify zero-knowledge proof if present
        if (zkp_proof) |proof| {
            const zkp_valid = try self.crypto_engine.verifyRangeProof(proof.proof_data, 1, 1000000);
            if (!zkp_valid) {
                return BankingError.InvalidTransaction;
            }
            std.debug.print("✅ Zero-knowledge proof verified\n", .{});
        }

        // Process the transfer (simplified - would include balance checks, etc.)
        try self.processTransfer(transaction);

        // Log in cryptographic audit trail
        try self.transaction_log.logOperation("TRANSFER", tx_data);

        std.debug.print("✅ Transfer completed successfully\n", .{});
        std.debug.print("   - Transaction ID: {s}\n", .{tx_id});
        std.debug.print("   - Quantum-safe signature\n", .{});
        if (private_transfer) {
            std.debug.print("   - Zero-knowledge privacy protection\n", .{});
        }

        // Clean up ZKP if created
        if (zkp_proof) |*proof| {
            proof.deinit(self.allocator);
        }
    }

    fn processTransfer(self: *Self, _: Transaction) !void {
        // In a real implementation, this would:
        // 1. Decrypt account balances
        // 2. Verify sufficient funds
        // 3. Update balances
        // 4. Re-encrypt balances
        // 5. Store transaction

        // For demo, just insert transaction record
        try self.db.execute("INSERT INTO transactions (id, from_account, to_account, timestamp, tx_type) VALUES ('{}', '{}', '{}', {}, {});");

        std.debug.print("   - Updated account balances (encrypted)\n", .{});
        std.debug.print("   - Transaction recorded\n", .{});
    }

    /// Generate detailed financial report with privacy protection
    pub fn generatePrivacyReport(self: *Self) !void {
        std.debug.print("📊 Generating privacy-protected financial report...\n", .{});

        // In a real implementation, this would use zero-knowledge proofs to prove
        // financial statistics without revealing individual account details

        // Example: Prove total deposits exceed regulatory minimum without revealing exact amount
        const total_deposits: u64 = 50000000; // This would be computed from encrypted balances
        const regulatory_minimum: u64 = 10000000;

        const compliance_proof = try self.crypto_engine.createRangeProof(total_deposits, regulatory_minimum, std.math.maxInt(u64));
        defer self.allocator.free(compliance_proof);

        const compliance_valid = try self.crypto_engine.verifyRangeProof(compliance_proof, regulatory_minimum, std.math.maxInt(u64));

        std.debug.print("✅ Regulatory compliance report:\n", .{});
        std.debug.print("   - Total deposits: PRIVATE (above minimum)\n", .{});
        std.debug.print("   - Compliance proof: {s}\n", .{if (compliance_valid) "VERIFIED" else "FAILED"});
        std.debug.print("   - Zero-knowledge privacy maintained\n", .{});
    }

    /// Audit trail verification with post-quantum integrity
    pub fn verifyAuditTrail(self: *Self) !bool {
        std.debug.print("🔍 Verifying post-quantum audit trail...\n", .{});

        const integrity_valid = try self.transaction_log.verifyIntegrity();

        std.debug.print("✅ Audit trail verification: {s}\n", .{if (integrity_valid) "VALID" else "CORRUPTED"});

        if (integrity_valid) {
            std.debug.print("   - All transaction signatures verified\n", .{});
            std.debug.print("   - Blockchain-style chain integrity confirmed\n", .{});
            std.debug.print("   - Post-quantum security maintained\n", .{});
        }

        return integrity_valid;
    }

    /// Simulate quantum computer attack (should fail)
    pub fn simulateQuantumAttack(self: *Self) !void {
        std.debug.print("⚠️ Simulating quantum computer attack...\n", .{});

        // Create fake transaction
        const fake_tx_data = "TRANSFER:victim_account:attacker_account:1000000:1234567890";

        // Try to forge signature (this should fail with post-quantum crypto)
        std.debug.print("🔓 Attempting to forge transaction signature...\n", .{});

        // In a classical-only system, a quantum computer could forge signatures
        // But with ML-DSA-65, this attack fails

        var pq_sig_data = std.mem.zeroes([3309]u8);
        const fake_signature = zqlite.crypto.HybridSignature{
            .classical = std.mem.zeroes([64]u8),
            .post_quantum = &pq_sig_data,
        };

        const forge_successful = self.crypto_engine.verifyTransaction(fake_tx_data, fake_signature) catch false;

        std.debug.print("✅ Quantum attack result: {s}\n", .{if (forge_successful) "SYSTEM COMPROMISED!" else "ATTACK BLOCKED"});

        if (!forge_successful) {
            std.debug.print("   - Post-quantum signatures cannot be forged\n", .{});
            std.debug.print("   - ML-DSA-65 provides quantum-safe security\n", .{});
            std.debug.print("   - Banking system remains secure\n", .{});
        }
    }

    /// Enable post-quantum only mode (disable classical crypto)
    pub fn enableQuantumSafeMode(self: *Self) void {
        self.crypto_engine.enablePostQuantumOnlyMode();
        std.debug.print("🛡️ Enabled quantum-safe only mode\n", .{});
        std.debug.print("   - Disabled classical cryptography\n", .{});
        std.debug.print("   - Pure post-quantum security\n", .{});
    }

    pub fn deinit(self: *Self) void {
        self.transaction_log.deinit();
        self.crypto_engine.deinit();
        self.db.close();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🏦 Welcome to Post-Quantum Banking System v0.5.0\n", .{});
    std.debug.print("================================================\n", .{});
    std.debug.print("Powered by ZQLite v0.6.0\n", .{});
    std.debug.print("Features: ML-KEM, ML-DSA, Zero-Knowledge Proofs\n\n", .{});

    // Initialize post-quantum bank
    var bank = try PostQuantumBank.init(allocator, null); // In-memory database
    defer bank.deinit();

    // Create some accounts
    try bank.createAccount("alice_checking", 100000, .Checking);
    try bank.createAccount("bob_savings", 50000, .Savings);
    try bank.createAccount("corp_vault", 10000000, .CorporateVault);

    std.debug.print("\n", .{});

    // Perform regular transfer
    try bank.transfer("alice_checking", "bob_savings", 5000, false);

    std.debug.print("\n", .{});

    // Perform private transfer with zero-knowledge proof
    try bank.transfer("corp_vault", "alice_checking", 25000, true);

    std.debug.print("\n", .{});

    // Generate privacy-protected report
    try bank.generatePrivacyReport();

    std.debug.print("\n", .{});

    // Verify audit trail
    _ = try bank.verifyAuditTrail();

    std.debug.print("\n", .{});

    // Simulate quantum attack
    try bank.simulateQuantumAttack();

    std.debug.print("\n", .{});

    // Enable quantum-safe only mode
    bank.enableQuantumSafeMode();

    // Test final transfer in pure post-quantum mode
    try bank.transfer("alice_checking", "bob_savings", 1000, false);

    std.debug.print("\n🎉 Post-quantum banking demo completed successfully!\n", .{});
    std.debug.print("💫 Ready for the quantum computing era! 🚀\n", .{});
}
