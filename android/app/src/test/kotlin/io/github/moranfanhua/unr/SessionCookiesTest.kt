package io.github.moranfanhua.unr

import org.junit.Assert.*
import org.junit.Test

class SessionCookiesTest {
    @Test fun capturesOnlySelectedPlatformAndAuthCookies() {
        val collector = SessionCookies(SessionPlatform.FANQIE)
        assertNull(collector.add("fanqienovel.com.evil.test", "sessionid=secret"))
        assertNull(collector.add("sfacg.com", "sessionid=secret"))
        assertEquals("sessionid=synthetic", collector.add("fanqienovel.com", "tracking_id=no; sessionid=synthetic"))
        assertNull(collector.add("fanqienovel.com", "sessionid=injected\r\nX-Header: bad"))
        collector.clear()
        assertNull(collector.add("fanqienovel.com", "uid_tt=123"))
    }

    @Test fun mergesSfacgCookiesWithoutInventingAppSession() {
        val collector = SessionCookies(SessionPlatform.SFACG)
        assertNull(collector.add("m.sfacg.com", "session_APP=app"))
        assertEquals("session_APP=app; .SFCommunity=web", collector.add("api.sfacg.com", ".SFCommunity=web"))
        collector.clear()
        assertEquals(".SFCommunity=web", collector.add("m.sfacg.com", ".SFCommunity=web"))
    }

    @Test fun blocksUntrustedLoginNavigationAndUnsafeCookieValues() {
        val platform = SessionPlatform.FANQIE
        assertTrue(platform.acceptsNavigation("https://fanqienovel.com/"))
        assertTrue(platform.acceptsNavigation("https://sso.douyin.com/login"))
        for (url in listOf("http://fanqienovel.com/", "https://evil.test/", "file:///data/", "https://user@fanqienovel.com/", "https://fanqienovel.com:444/")) {
            assertFalse(url, platform.acceptsNavigation(url))
        }
        val collector = SessionCookies(platform)
        assertNull(collector.add("fanqienovel.com", "sessionid=" + "x".repeat(17000)))
        assertThrows(IllegalArgumentException::class.java) { SessionPlatform.fromId("other") }
    }
}
