package app.dictation.keyboard

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PrefsTest {
    private val prefs = Prefs(ApplicationProvider.getApplicationContext<Context>().getSharedPreferences("test", Context.MODE_PRIVATE))

    @Test
    fun polishIsOnAndCloudFlashChosenByDefault() {
        assertTrue(prefs.polishEnabled)
        assertTrue(prefs.backupWhenSlow)
        assertEquals(Mode.VOICE, prefs.mode)
        assertEquals("cloud-flash", prefs.setup(TestFiles.setups).id)
    }

    @Test
    fun aRemovedSetupFallsBackToTheDefault() {
        prefs.setupId = "cloud-big"
        assertEquals("cloud-big", prefs.setup(TestFiles.setups).id)
        prefs.setupId = "gone"
        assertEquals("cloud-flash", prefs.setup(TestFiles.setups).id)
    }
}
