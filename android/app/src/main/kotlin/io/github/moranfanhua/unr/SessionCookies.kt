package io.github.moranfanhua.unr

enum class SessionPlatform(val id: String, val title: String) {
    SFACG("sfacg", "菠萝包"),
    FANQIE("fanqie", "番茄小说");

    val appPackage get() = when (this) {
        SFACG -> "com.sfacg"
        FANQIE -> "com.dragon.read"
    }
    val appHosts get() = when (this) {
        SFACG -> listOf("api.sfacg.com")
        FANQIE -> listOf("fqnovel.com", "fanqienovel.com", "reading.snssdk.com", "novel.snssdk.com", "security.snssdk.com")
    }
    fun acceptsAppHost(host: String): Boolean {
        val normalized = host.lowercase().trimEnd('.')
        return appHosts.any { normalized == it || normalized.endsWith(".$it") }
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

    @Synchronized fun addApp(host: String, header: String): String? = collect(host, header)

    @Synchronized fun addAppSetCookie(host: String, header: String): String? {
        if (header.length > 16384 || header.any { it.code < 32 || it.code == 127 }) return null
        var result: String? = null
        for (part in header.split(Regex(",\\s*(?=[.A-Za-z0-9_-]+=)"))) {
            val pair = part.substringBefore(';')
            val deletion = part.split(';').drop(1).any { it.trim().equals("Max-Age=0", true) }
            result = collect(host, if (deletion) pair.substringBefore('=') + "=" else pair)
        }
        return result
    }

    private fun collect(host: String, header: String): String? {
        if (!platform.acceptsAppHost(host) || header.length > 16384 || header.any { it.code < 32 || it.code == 127 }) return null
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
            SessionPlatform.SFACG -> values[".SFCommunity"]?.isNotEmpty() == true && values["session_APP"]?.isNotEmpty() == true
            SessionPlatform.FANQIE -> values["sessionid"]?.isNotEmpty() == true || values["sessionid_ss"]?.isNotEmpty() == true
        }
        return if (ready) values.entries.joinToString("; ") { "${it.key}=${it.value}" } else null
    }

    @Synchronized fun clear() { values.clear() }
}
