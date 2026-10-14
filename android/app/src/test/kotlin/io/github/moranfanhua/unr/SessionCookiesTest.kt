package io.github.moranfanhua.unr

import org.junit.Assert.*
import org.junit.Test

class SessionCookiesTest {
    @Test fun capturesCompleteAppSessionAcrossLoginResponseAndRequest() {
        val collector = SessionCookies(SessionPlatform.SFACG)
        assertNull(collector.addApp("m.sfacg.com", ".SFCommunity=web; session_APP=wrong"))
        assertNull(collector.addApp("api.sfacg.com", ".SFCommunity=app-community"))
        assertEquals(".SFCommunity=app-community; session_APP=app-session", collector.addAppSetCookie(
            "api.sfacg.com", "session_APP=app-session; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Secure; HttpOnly"))
        assertNull(collector.addAppSetCookie("api.sfacg.com", "session_APP=expired; Max-Age=0; Path=/"))
        collector.clear()
        assertEquals(".SFCommunity=community; session_APP=session", collector.addAppSetCookie(
            "api.sfacg.com", ".SFCommunity=community; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT, session_APP=session; Path=/"))
    }

    @Test fun isolatesOfficialAppHostsAndKeepsOnlyAuthCookies() {
        val platform = SessionPlatform.FANQIE
        assertEquals("com.dragon.read", platform.appPackage)
        assertEquals("com.sfacg", SessionPlatform.SFACG.appPackage)
        assertTrue(platform.acceptsAppHost("api5-normal-lf.fqnovel.com"))
        assertFalse(platform.acceptsAppHost("fqnovel.com.evil.test"))
        val collector = SessionCookies(platform)
        assertNull(collector.addAppSetCookie("sfacg.com", "sessionid=other-platform"))
        assertNull(collector.addAppSetCookie("api5-normal-lf.fqnovel.com", "sessionid=bad\r\nInjected=header"))
        assertEquals("sessionid=app-session", collector.addAppSetCookie("api5-normal-lf.fqnovel.com", "sessionid=app-session; Path=/; Secure; HttpOnly, tracking_id=ignored; Path=/"))
    }

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
