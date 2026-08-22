package dev.notifie

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Parsing the configuration that replaces google-services.json.
 *
 * A half-populated configuration is worse than none: Firebase accepts it, the
 * device gets a token, and delivery fails later in a way that looks like a
 * Notifie bug rather than a setup problem. So anything incomplete has to be
 * refused here, where falling back to google-services.json is still possible.
 */
// Robolectric supplies a real org.json; the plain android.jar stub throws.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32])
class NotifiePushConfigTest {
    @Test
    fun `reads a complete configuration`() {
        val config = NotifiePushConfig.parse(
            """
            {"android":{"projectId":"demo","applicationId":"1:1:android:a",
            "apiKey":"AIzaKey","senderId":"754795614042"}}
            """.trimIndent(),
        )

        assertEquals("demo", config?.projectId)
        assertEquals("1:1:android:a", config?.applicationId)
        assertEquals("AIzaKey", config?.apiKey)
        assertEquals("754795614042", config?.senderId)
    }

    @Test
    fun `treats an absent configuration as nothing to do`() {
        // The server answers 200 with android:null when no Firebase credential
        // has been uploaded. That is a normal state, not a failure.
        assertNull(NotifiePushConfig.parse("""{"android":null}"""))
        assertNull(NotifiePushConfig.parse("""{}"""))
    }

    @Test
    fun `refuses a configuration missing any required value`() {
        val fields = listOf("projectId", "applicationId", "apiKey", "senderId")
        for (missing in fields) {
            val values = fields.associateWith { if (it == missing) "" else "value" }
            val json = values.entries.joinToString(",") { """"${it.key}":"${it.value}"""" }
            assertNull("blank $missing must be refused", NotifiePushConfig.parse("""{"android":{$json}}"""))
        }
    }

    @Test
    fun `refuses malformed responses instead of throwing`() {
        // A proxy or captive portal can return HTML with a 200. Throwing here
        // would surface as a crash during push enrolment.
        assertNull(NotifiePushConfig.parse("<html>not json</html>"))
        assertNull(NotifiePushConfig.parse(""))
    }
}
