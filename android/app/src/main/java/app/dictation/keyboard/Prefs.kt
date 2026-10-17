package app.dictation.keyboard

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The keyboard's settings. Defaults differ from the Mac app's where the phone differs (polish on, cloud setup). */
class Prefs(private val prefs: SharedPreferences) {
    constructor(context: Context) : this(context.getSharedPreferences("settings", Context.MODE_PRIVATE))

    /** AI polish: on by default here (off on the Mac). */
    var polishEnabled: Boolean
        get() = prefs.getBoolean("aiPolishEnabled", true)
        set(value) = prefs.edit().putBoolean("aiPolishEnabled", value).apply()

    var setupId: String
        get() = prefs.getString("setup", Setups.DEFAULT_ID) ?: Setups.DEFAULT_ID
        set(value) = prefs.edit().putString("setup", value).apply()

    /** "Backup model when slow", on by default as on the Mac. */
    var backupWhenSlow: Boolean
        get() = prefs.getBoolean("backupWhenSlow", true)
        set(value) = prefs.edit().putBoolean("backupWhenSlow", value).apply()

    /** The panel the keyboard opens on: voice by default. */
    var mode: Mode
        get() = runCatching { Mode.valueOf(prefs.getString("mode", null) ?: "") }.getOrDefault(Mode.VOICE)
        set(value) = prefs.edit().putString("mode", value.name).apply()

    /** The chosen setup, or the default if it's gone. */
    fun setup(setups: List<Setup>): Setup = setups.firstOrNull { it.id == setupId }
        ?: setups.firstOrNull { it.id == Setups.DEFAULT_ID } ?: setups.first()
}

/** Where the OpenRouter API key is kept (in memory in tests). */
interface SecretStore {
    var apiKey: String?
}

/**
 * The API key encrypted with an AES-GCM key held in the Android Keystore (it never leaves the
 * secure hardware where there is one), so the stored ciphertext alone is useless: not in backups
 * (allowBackup is off as well), not in a copy of the app's files.
 */
class KeystoreSecretStore(context: Context) : SecretStore {
    private val prefs = context.getSharedPreferences("secrets", Context.MODE_PRIVATE)

    override var apiKey: String?
        get() = prefs.getString(KEY, null)?.let { stored ->
            runCatching {
                val bytes = Base64.decode(stored, Base64.NO_WRAP)
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, IV_BYTES))
                String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES))
            }.getOrNull()
        }
        set(value) {
            if (value.isNullOrBlank()) return prefs.edit().remove(KEY).apply()
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val sealed = cipher.iv + cipher.doFinal(value.trim().toByteArray())
            prefs.edit().putString(KEY, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
        }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build())
            generateKey()
        }
    }

    private companion object {
        const val KEY = "openRouterKey"
        const val ALIAS = "openrouter-api-key"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}
