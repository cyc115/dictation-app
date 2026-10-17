package app.dictation.keyboard

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.View
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView

/** Setup (turn on the keyboard, mic, API key) and the dictation options. Opened from the launcher or the keyboard's name. */
class SettingsActivity : Activity() {
    private lateinit var prefs: Prefs
    private lateinit var secrets: SecretStore
    private val steps = mutableListOf<() -> Unit>()  // re-checked on every resume

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = Prefs(this)
        secrets = KeystoreSecretStore(this)
        val setups = Setups.load { assets.open(it).bufferedReader().use { r -> r.readText() } }
        val pad = (20 * resources.displayMetrics.density).toInt()
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(pad, pad, pad, pad) }

        column.addView(text("Dictation Keyboard", 26f))
        column.addView(text("Tap to dictate in any app, with the Mac app's cloud models and AI polish. Type or swipe in English and 拼音.", 15f))

        heading(column, "Set up")
        step(column, "1. Turn on Dictation Keyboard", "Open keyboard settings", { enabled() }) {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        step(column, "2. Switch to it", "Choose keyboard", { selected() }, keepEnabled = true) {
            getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }
        step(column, "3. Allow the microphone", "Allow", { micAllowed() }) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        }

        heading(column, "4. OpenRouter API key")
        val keyStatus = text("", 14f)
        val keyField = EditText(this).apply {
            hint = "sk-or-…"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            isSingleLine = true
        }
        val save = Button(this).apply {
            text = "Save key"
            setOnClickListener {
                secrets.apiKey = keyField.text.toString()
                keyField.setText("")
                steps.forEach { it() }
            }
        }
        column.addView(keyField); column.addView(save); column.addView(keyStatus)
        steps += {
            keyStatus.text = secrets.apiKey?.let { "✓ Saved (…${it.takeLast(4)}), encrypted by the Android Keystore." }
                ?: "Not set. Use a key with a credit limit (openrouter.ai → Keys): it lives on your phone."
        }

        heading(column, "Model")
        val group = RadioGroup(this)
        setups.forEachIndexed { i, setup ->
            group.addView(RadioButton(this).apply {
                id = View.generateViewId()
                text = "${setup.title}\n${setup.summary}"
                isChecked = setup.id == prefs.setup(setups).id
                setOnClickListener { prefs.setupId = setup.id }
                tag = i
            })
        }
        column.addView(group)

        heading(column, "Options")
        column.addView(switch("AI polish", "Removes filler words and fixes self-corrections, with the Mac app's prompt. Also on the keyboard's ✎ button.",
            prefs.polishEnabled) { prefs.polishEnabled = it })
        column.addView(switch("Backup model when slow", "If the speech model hasn't answered after a couple of seconds, a faster one is asked too.",
            prefs.backupWhenSlow) { prefs.backupWhenSlow = it })

        heading(column, "Try it")
        column.addView(EditText(this).apply { hint = "Tap here, then the keyboard's big button"; minLines = 3 })

        setContentView(ScrollView(this).apply {
            addView(column)
            setOnApplyWindowInsetsListener { v, insets ->
                val (top, bottom) = if (Build.VERSION.SDK_INT >= 30) {
                    val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
                    bars.top to bars.bottom
                } else {
                    @Suppress("DEPRECATION") insets.systemWindowInsetTop to insets.systemWindowInsetBottom
                }
                v.setPadding(0, top, 0, bottom)
                insets
            }
        })
    }

    override fun onResume() {
        super.onResume()
        steps.forEach { it() }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) steps.forEach { it() }  // after the keyboard picker closes
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        steps.forEach { it() }
    }

    private fun enabled() = getSystemService(InputMethodManager::class.java).enabledInputMethodList.any { it.packageName == packageName }

    private fun selected() = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)?.startsWith("$packageName/") == true

    private fun micAllowed() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun text(value: String, size: Float) = TextView(this).apply {
        text = value
        textSize = size
        setPadding(0, 8, 0, 8)
    }

    private fun heading(column: LinearLayout, title: String) {
        column.addView(text(title, 19f).apply { setPadding(0, (24 * resources.displayMetrics.density).toInt(), 0, 8) })
    }

    private fun step(column: LinearLayout, title: String, action: String, done: () -> Boolean, keepEnabled: Boolean = false, run: () -> Unit) {
        val label = text(title, 16f)
        val button = Button(this).apply { text = action; setOnClickListener { run() } }
        column.addView(label); column.addView(button)
        steps += {
            val ok = done()
            label.text = (if (ok) "✓ " else "") + title
            button.isEnabled = !ok || keepEnabled
        }
    }

    @Suppress("DEPRECATION")  // android.widget.Switch: no AndroidX dependency for one toggle
    private fun switch(title: String, help: String, on: Boolean, changed: (Boolean) -> Unit) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(Switch(this@SettingsActivity).apply {
            text = title
            textSize = 16f
            isChecked = on
            setOnCheckedChangeListener { _, value -> changed(value) }
        })
        addView(text(help, 13f))
    }
}
