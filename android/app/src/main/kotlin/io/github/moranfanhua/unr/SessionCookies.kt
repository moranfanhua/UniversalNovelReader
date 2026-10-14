package io.github.moranfanhua.unr

import java.net.URI

enum class SessionPlatform(val id: String, val title: String, val loginUrl: String) {
    SFACG("sfacg", "菠萝包", "https://m.sfacg.com/login/"),
    FANQIE("fanqie", "番茄小说", "https://fanqienovel.com/main/writer/login");

    val userAgentMarker get() = "UNRSessionLogin/$id"

    fun acceptsHost(host: String): Boolean {
        val normalized = host.lowercase().trimEnd('.')
        return when (this) {
            SFACG -> normalized == "sfacg.com" || normalized.endsWith(".sfacg.com")
            FANQIE -> normalized == "fanqienovel.com" || normalized.endsWith(".fanqienovel.com")
        }
    }

    fun acceptsNavigation(url: String): Boolean = try {
        val uri = URI(url)
        uri.scheme == "https" && uri.userInfo == null && (uri.port == -1 || uri.port == 443) &&
            (acceptsHost(uri.host ?: "") || this == FANQIE && listOf(
                "snssdk.com", "bytedance.com", "toutiao.com", "douyin.com"
            ).any { uri.host == it || uri.host?.endsWith(".$it") == true })
    } catch (_: Exception) { false }

    val cookieUrls: List<String> get() = when (this) {
        SFACG -> listOf("https://passport.sfacg.com/", "https://m.sfacg.com/", "https://book.sfacg.com/", "https://api.sfacg.com/")
        FANQIE -> listOf("https://fanqienovel.com/", "https://www.fanqienovel.com/")
    }

    companion object {
        fun fromId(id: String?): SessionPlatform = entries.firstOrNull { it.id == id }
            ?: throw IllegalArgumentException("不支持的账号平台")
    }
}

class SessionCookies(private val platform: SessionPlatform) {
    private val values = linkedMapOf<String, String>()
    private val allowed = when (platform) {
        SessionPlatform.SFACG -> setOf(".SFCommunity", "session_APP")
        SessionPlatform.FANQIE -> setOf("sessionid", "sessionid_ss", "sid_tt", "sid_guard", "uid_tt",
            "uid_tt_ss", "passport_csrf_token", "passport_csrf_token_default", "sid_ucp_v1", "ssid_ucp_v1")
    }

    @Synchronized fun add(host: String, header: String): String? {
        if (!platform.acceptsHost(host) || header.length > 16384 || header.any { it.code < 32 || it.code == 127 }) return null
        for (part in header.split(';')) {
            val index = part.indexOf('=')
            if (index < 1) continue
            val key = part.substring(0, index).trim()
            val value = part.substring(index + 1).trim()
            if (key in allowed) {
                if (value.isEmpty()) values.remove(key) else values[key] = value
            }
        }
        val ready = when (platform) {
            SessionPlatform.SFACG -> values[".SFCommunity"]?.isNotEmpty() == true
            SessionPlatform.FANQIE -> values["sessionid"]?.isNotEmpty() == true || values["sessionid_ss"]?.isNotEmpty() == true
        }
        return if (ready) values.entries.joinToString("; ") { "${it.key}=${it.value}" } else null
    }

    @Synchronized fun clear() { values.clear() }
}
