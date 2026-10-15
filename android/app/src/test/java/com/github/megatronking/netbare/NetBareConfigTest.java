package com.github.megatronking.netbare;

import org.junit.Test;
import java.util.ArrayList;
import java.util.Arrays;
import static org.junit.Assert.assertEquals;

public class NetBareConfigTest {
    @Test public void keepsSystemDnsPriorityAndRemovesDuplicates() {
        NetBareConfig config = NetBareConfig.defaultConfig().newBuilder()
                .addDnsServer("28.0.0.2")
                .addDnsServer("202.115.39.6")
                .addDnsServer("202.115.39.9")
                .addDnsServer("28.0.0.2")
                .build();
        assertEquals(Arrays.asList("28.0.0.2", "202.115.39.6", "202.115.39.9"),
                new ArrayList<>(config.dnsServers));
    }
}
