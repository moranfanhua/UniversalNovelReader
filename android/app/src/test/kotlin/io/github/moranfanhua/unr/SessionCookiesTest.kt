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
        assertTrue(platform.acceptsAppHost("security.snssdk.com"))
        assertFalse(platform.acceptsAppHost("security.snssdk.com.evil.test"))
        assertFalse(platform.acceptsAppHost("fqnovel.com.evil.test"))
        val collector = SessionCookies(platform)
        assertNull(collector.addAppSetCookie("sfacg.com", "sessionid=other-platform"))
        assertNull(collector.addAppSetCookie("api5-normal-lf.fqnovel.com", "sessionid=bad\r\nInjected=header"))
        assertEquals("sessionid=app-session", collector.addAppSetCookie("api5-normal-lf.fqnovel.com", "sessionid=app-session; Path=/; Secure; HttpOnly, tracking_id=ignored; Path=/"))
        collector.clear()
        assertEquals("sessionid=login-session", collector.addAppSetCookie("security.snssdk.com", "sessionid=login-session; Domain=.snssdk.com; Secure; HttpOnly"))
    }

    @Test fun appCaptureRejectsIncompleteSessionsAndUnsafeHeaders() {
        val sf = SessionCookies(SessionPlatform.SFACG)
        assertNull(sf.addApp("m.sfacg.com", ".SFCommunity=web"))
        assertNull(sf.addApp("api.sfacg.com", ".SFCommunity=community"))
        assertEquals(".SFCommunity=community; session_APP=app", sf.addApp("api.sfacg.com", "session_APP=app"))
        sf.clear()
        assertNull(sf.addApp("api.sfacg.com", "session_APP=app"))
        val fq = SessionCookies(SessionPlatform.FANQIE)
        assertNull(fq.addApp("fqnovel.com.evil.test", "sessionid=secret"))
        assertNull(fq.addApp("sfacg.com", "sessionid=secret"))
        assertNull(fq.addApp("reading.snssdk.com", "sessionid=bad\r\nInjected=header"))
        assertNull(fq.addApp("reading.snssdk.com", "sessionid=" + "x".repeat(17000)))
        assertEquals("sessionid=synthetic", fq.addApp("reading.snssdk.com", "tracking_id=no; sessionid=synthetic"))
        fq.clear()
        assertNull(fq.addApp("reading.snssdk.com", "uid_tt=123"))
        assertThrows(IllegalArgumentException::class.java) { SessionPlatform.fromId("other") }
    }
}
