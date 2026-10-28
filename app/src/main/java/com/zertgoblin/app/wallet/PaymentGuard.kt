package com.zertgoblin.app.wallet

import android.util.Base64
import com.zertgoblin.app.game.GameConfig
import com.zertgoblin.app.util.Base58

/**
 * UMBRA C-5, shell half: the pre-signing assertion.
 *
 * The game client decodes and asserts its own built transaction
 * before offering it to a wallet (client/src/payments.ts,
 * `assertBuiltPayment`). The shell does NOT trust that the page in
 * the WebView is the honest client — a compromised or substituted
 * page could hand the bridge any bytes it likes. So before ANY
 * transaction reaches Mobile Wallet Adapter, the shell decodes the
 * serialized legacy transaction itself and asserts, against the
 * SHELL's own constants (GameConfig):
 *
 *  - the program set is only {System, Token, Associated Token Account}
 *  - the fee payer is the connected wallet
 *  - the value transfer lands on the game's receiving wallet
 *    (SOL: a System transfer to RECEIVING_WALLET; USDC: a
 *    TransferChecked into RECEIVING_USDC_ATA of the USDC mint) —
 *    never anywhere else
 *  - the transferred amount (read from the instruction data itself)
 *    is exactly the amount encoded for that checked destination:
 *    one transfer instruction only, so there is no second,
 *    unchecked amount hiding in the transaction
 *  - the only permitted extra instruction is creating the receiving
 *    wallet's USDC account (the genesis case the client builds)
 *
 * Any mismatch refuses the handoff with
 * `shell_assertion_failed: <detail>` and the wallet never sees the
 * transaction. Amounts the shell cannot check against a quote (the
 * quote lives server-side) are still quote-bound end-to-end: the
 * server only grants against its own issued quote, and the client
 * asserts the amount against that quote before the bridge is called.
 */
object PaymentGuard {

    sealed interface Verdict {
        data object Ok : Verdict
        data class Refuse(val detail: String) : Verdict
    }

    private class Reader(private val bytes: ByteArray) {
        var pos: Int = 0
            private set

        fun u8(): Int {
            require(pos < bytes.size) { "truncated transaction" }
            return bytes[pos++].toInt() and 0xFF
        }

        fun take(n: Int): ByteArray {
            require(n >= 0 && pos + n <= bytes.size) { "truncated transaction" }
            val out = bytes.copyOfRange(pos, pos + n)
            pos += n
            return out
        }

        fun shortvec(): Int {
            var value = 0
            var shift = 0
            while (true) {
                val byte = u8()
                value = value or ((byte and 0x7F) shl shift)
                if (byte and 0x80 == 0) return value
                shift += 7
                require(shift <= 28) { "malformed shortvec" }
            }
        }
    }

    private data class Instruction(
        val programId: String,
        val accounts: List<String>,
        val data: ByteArray
    )

    private data class Decoded(
        val feePayer: String,
        val accountKeys: List<String>,
        val instructions: List<Instruction>
    )

    private fun decode(serialized: ByteArray): Decoded {
        val r = Reader(serialized)
        val sigCount = r.shortvec()
        r.take(sigCount * 64) // signature slots
        r.take(3) // message header
        val keyCount = r.shortvec()
        val keys = (0 until keyCount).map { Base58.encode(r.take(32)) }
        r.take(32) // recent blockhash
        val ixCount = r.shortvec()
        val instructions = (0 until ixCount).map {
            val programId = keys[r.u8()]
            val accountCount = r.shortvec()
            val accounts = (0 until accountCount).map { keys[r.u8()] }
            val dataLength = r.shortvec()
            val data = r.take(dataLength)
            Instruction(programId, accounts, data)
        }
        require(keys.isNotEmpty()) { "no account keys" }
        return Decoded(keys[0], keys, instructions)
    }

    private fun u32le(data: ByteArray, offset: Int): Long {
        var value = 0L
        for (i in 3 downTo 0) value = (value shl 8) or (data[offset + i].toLong() and 0xFF)
        return value
    }

    private fun u64le(data: ByteArray, offset: Int): Long {
        var value = 0L
        for (i in 7 downTo 0) value = (value shl 8) or (data[offset + i].toLong() and 0xFF)
        return value
    }

    /**
     * Assert [serializedBase64] is exactly a Zert Goblin payment from
     * [expectedFeePayer] (the connected wallet; may be null when the
     * session state is unknown, in which case the fee-payer check is
     * skipped — the wallet itself enforces that it only signs for its
     * own accounts).
     */
    fun assertPayment(serializedBase64: String, expectedFeePayer: String?): Verdict {
        val bytes = try {
            Base64.decode(serializedBase64, Base64.NO_WRAP)
        } catch (e: Exception) {
            return Verdict.Refuse("transaction is not valid base64")
        }
        val tx = try {
            decode(bytes)
        } catch (e: Exception) {
            return Verdict.Refuse("transaction bytes are unreadable: ${e.message}")
        }

        if (expectedFeePayer != null && tx.feePayer != expectedFeePayer) {
            return Verdict.Refuse("fee payer is not the connected wallet")
        }

        val allowedPrograms = setOf(GameConfig.SYSTEM_PROGRAM, GameConfig.TOKEN_PROGRAM, GameConfig.ATA_PROGRAM)
        for (ix in tx.instructions) {
            if (ix.programId !in allowedPrograms) {
                return Verdict.Refuse("an unexpected program is in the transaction")
            }
        }
        if (tx.instructions.isEmpty()) return Verdict.Refuse("transaction has no instructions")

        val transfer = tx.instructions.last()
        return when (transfer.programId) {
            GameConfig.SYSTEM_PROGRAM -> assertSolPayment(tx, transfer)
            GameConfig.TOKEN_PROGRAM -> assertUsdcPayment(tx, transfer)
            else -> Verdict.Refuse("the final instruction is not a payment transfer")
        }
    }

    /** SOL form: a single SystemProgram transfer to the receiving wallet. */
    private fun assertSolPayment(tx: Decoded, transfer: Instruction): Verdict {
        if (tx.instructions.size != 1) return Verdict.Refuse("a SOL payment must be a single transfer")
        if (transfer.data.size != 12) return Verdict.Refuse("the transfer data is malformed")
        if (u32le(transfer.data, 0) != 2L) return Verdict.Refuse("the instruction is not a SOL transfer")
        if (u64le(transfer.data, 4) <= 0) return Verdict.Refuse("the transfer amount must be positive")
        if (transfer.accounts.size < 2) return Verdict.Refuse("the transfer is missing accounts")
        if (transfer.accounts[0] != tx.feePayer) return Verdict.Refuse("the sender differs from the fee payer")
        if (transfer.accounts[1] != GameConfig.RECEIVING_WALLET) {
            return Verdict.Refuse("the destination is not the game's receiving wallet")
        }
        return Verdict.Ok
    }

    /**
     * USDC form: an optional CreateAssociatedTokenAccount for the
     * receiving wallet's USDC account, then exactly one
     * TransferChecked of a positive amount into that account.
     */
    private fun assertUsdcPayment(tx: Decoded, transfer: Instruction): Verdict {
        if (tx.instructions.size > 2) return Verdict.Refuse("unexpected extra instructions")
        if (tx.instructions.size == 2) {
            val create = tx.instructions[0]
            if (create.programId != GameConfig.ATA_PROGRAM) {
                return Verdict.Refuse("the extra instruction is not a token-account creation")
            }
            if (GameConfig.RECEIVING_USDC_ATA !in create.accounts) {
                return Verdict.Refuse("the token-account creation names a different account")
            }
            if (GameConfig.RECEIVING_WALLET !in create.accounts) {
                return Verdict.Refuse("the token-account creation names a different owner")
            }
            if (GameConfig.USDC_MINT !in create.accounts) {
                return Verdict.Refuse("the token-account creation names a different mint")
            }
        }
        if (transfer.data.size != 10 || (transfer.data[0].toInt() and 0xFF) != 12) {
            return Verdict.Refuse("the instruction is not a checked token transfer")
        }
        if (u64le(transfer.data, 1) <= 0) return Verdict.Refuse("the transfer amount must be positive")
        if ((transfer.data[9].toInt() and 0xFF) != 6) return Verdict.Refuse("the token decimals differ from USDC")
        if (transfer.accounts.size < 4) return Verdict.Refuse("the transfer is missing accounts")
        if (transfer.accounts[1] != GameConfig.USDC_MINT) return Verdict.Refuse("the mint is not USDC")
        if (transfer.accounts[2] != GameConfig.RECEIVING_USDC_ATA) {
            return Verdict.Refuse("the destination is not the game's USDC account")
        }
        if (transfer.accounts[3] != tx.feePayer) return Verdict.Refuse("the sender differs from the fee payer")
        return Verdict.Ok
    }
}
