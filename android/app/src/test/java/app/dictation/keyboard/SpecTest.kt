package app.dictation.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class SpecTest {
    @Test
    fun promptsAreExactlyTheBenchmarkedOnes() {
        val versions = File(TestFiles.specDir, "spec/prompts").list()!!.map { it.removeSuffix(".txt") }.sorted()
        assertTrue("v7" in versions)
        for (version in versions) {
            val benchmarked = File(TestFiles.repoRoot, "bench/polish_prompts/$version.txt").readText().trim()
            assertEquals(version, benchmarked, TestFiles.asset("spec/prompts/$version.txt").trim())
        }
    }

    @Test
    fun offersTheMacAppsCloudSetups() {
        val setups = TestFiles.setups
        assertEquals(listOf("cloud-flash", "cloud-big"), setups.map { it.id })  // On-device is Mac-only
        val flash = setups.first()
        assertEquals(ModelSpec("qwen/qwen3-asr-1.7b", null), flash.speech)
        assertEquals("qwen/qwen3-asr-0.6b", flash.backup)
        assertEquals(2.0, flash.backupWait, 0.0)
        assertEquals(ModelSpec("deepseek/deepseek-v4.1-flash", listOf("Together", "DeepInfra")), flash.polish)
        assertEquals(ModelSpec("deepseek/deepseek-v4.1-flash", listOf("DeepInfra", "Together")), flash.polishBackup)
        assertEquals(0.8, flash.polishBackupWait, 0.0)
        assertEquals(6.0, flash.polishDeadline, 0.0)  // the default, not in the JSON
        assertEquals("v7", flash.prompt)
        assertTrue(flash.promptText.startsWith("You clean up dictation transcripts."))
        assertTrue(flash.wrap)
        assertEquals(4.0, setups[1].backupWait, 0.0)
    }

    @Test
    fun parsesModelSpecs() {
        assertEquals(ModelSpec("m", null), ModelSpec.parse("openrouter:m"))
        assertEquals(ModelSpec("a/b", listOf("X", "Y")), ModelSpec.parse("openrouter:a/b@X,Y"))
        assertEquals("openrouter:a/b@X,Y", ModelSpec.parse("openrouter:a/b@X,Y").toString())
        assertNull(ModelSpec.parse("apple"))
        assertNull(ModelSpec.parse("openrouter:"))
    }
}
