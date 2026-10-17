package app.dictation.keyboard

import org.json.JSONArray
import org.json.JSONObject

/**
 * A cloud model as the Mac app's setups name it: "openrouter:<id>[@Provider[,Provider…]]"
 * (ModelSpec in Setups.swift). `providers`: only these OpenRouter hosts, in order; null lets
 * OpenRouter route.
 */
data class ModelSpec(val id: String, val providers: List<String>?) {
    override fun toString() = "openrouter:$id" + (providers?.let { "@" + it.joinToString(",") } ?: "")

    companion object {
        /** Null for anything but an OpenRouter model ("apple" is the Mac's on-device model). */
        fun parse(spec: String): ModelSpec? {
            if (!spec.startsWith("openrouter:")) return null
            val rest = spec.removePrefix("openrouter:")
            val id = rest.substringBefore("@")
            if (id.isEmpty()) return null
            return ModelSpec(id, if ("@" in rest) rest.substringAfter("@").split(",") else null)
        }
    }
}

/**
 * One of the Mac app's cloud setups (DictationSetup in Setups.swift): which model hears you, which
 * polishes, with what prompt, and when backups are asked. The phone has no on-device models, so
 * only setups whose speech and polish are both cloud models are offered.
 */
data class Setup(
    val id: String,
    val title: String,
    val summary: String,
    val speech: ModelSpec,
    /** Also asked when `speech` hasn't answered in `backupWait` seconds, or failed. */
    val backup: String?,
    val backupWait: Double,
    val polish: ModelSpec,
    /** Also asked when `polish` hasn't answered in `polishBackupWait` seconds, or failed. */
    val polishBackup: ModelSpec?,
    val polishBackupWait: Double,
    /** Seconds before you get the raw transcript instead of waiting for polish. */
    val polishDeadline: Double,
    /** The prompt version, e.g. "v7". */
    val prompt: String,
    val promptText: String,
    /** Send the transcript inside <transcript> tags. */
    val wrap: Boolean,
)

/** The Mac app's built-in setups and prompts, extracted from Setups.swift at build time (assets/spec/). */
object Setups {
    const val DEFAULT_ID = "cloud-flash"

    /** `read` returns an asset's text, e.g. "spec/setups.json". Defaults as in DictationSetup.init(from:). */
    fun load(read: (String) -> String): List<Setup> {
        val all = JSONArray(read("spec/setups.json"))
        return (0 until all.length()).map { all.getJSONObject(it) }.mapNotNull { s ->
            val speech = ModelSpec.parse(s.getString("speech")) ?: return@mapNotNull null
            val polish = ModelSpec.parse(s.getString("polish")) ?: return@mapNotNull null
            val prompt = s.getString("prompt")
            Setup(
                id = s.getString("id"),
                title = s.getString("title"),
                summary = s.optString("summary"),
                speech = speech,
                backup = s.stringOrNull("backup"),
                backupWait = s.optDouble("backupWait", 2.0),
                polish = polish,
                polishBackup = s.stringOrNull("polishBackup")?.let(ModelSpec::parse),
                polishBackupWait = s.optDouble("polishBackupWait", 0.8),
                polishDeadline = s.optDouble("polishDeadline", 6.0),
                prompt = prompt,
                promptText = read("spec/prompts/$prompt.txt").trim(),
                wrap = s.optBoolean("wrap", true),
            )
        }
    }

    private fun JSONObject.stringOrNull(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
}
