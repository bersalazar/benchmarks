/*
 * Copyright 2015-2025 Real Logic Limited.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.aeron.benchmarks.kafka;

import org.HdrHistogram.Histogram;
import org.agrona.concurrent.SystemNanoClock;
import org.apache.kafka.common.config.SslConfigs;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.condition.DisabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import io.aeron.benchmarks.Configuration;
import io.aeron.benchmarks.InMemoryMessageTransceiver;
import io.aeron.benchmarks.LoadTestRig;
import io.aeron.benchmarks.SinglePersistedHistogram;

import java.io.PrintStream;
import java.nio.file.Path;

import static java.lang.System.clearProperty;
import static java.lang.System.setProperty;
import static org.apache.kafka.clients.CommonClientConfigs.BOOTSTRAP_SERVERS_CONFIG;
import static org.apache.kafka.clients.CommonClientConfigs.SECURITY_PROTOCOL_CONFIG;
import static org.mockito.Mockito.mock;
import static io.aeron.benchmarks.kafka.KafkaConfig.PARTITION_SELECTION_PROP_NAME;

@DisabledOnOs(OS.WINDOWS) // Temporary until https://issues.apache.org/jira/browse/KAFKA-14273 is fixed
class KafkaMessageTransceiverTest
{
    private KafkaEmbeddedCluster cluster;

    @BeforeEach
    void setup(final @TempDir Path tempDir) throws Exception
    {
        cluster = new KafkaEmbeddedCluster(13501, 13502, 13503, tempDir);
    }

    @AfterEach
    void tearDown()
    {
        cluster.close();
    }

    @Timeout(30)
    @ParameterizedTest
    @EnumSource(PartitionSelection.class)
    void messageLength32bytes(final PartitionSelection partitionSelection) throws Exception
    {
        setProperty(BOOTSTRAP_SERVERS_CONFIG, "localhost:13501");
        setProperty(PARTITION_SELECTION_PROP_NAME, partitionSelection.name());
        try
        {
            test(500, 32, 10);
        }
        finally
        {
            clearProperty(BOOTSTRAP_SERVERS_CONFIG);
            clearProperty(PARTITION_SELECTION_PROP_NAME);
        }
    }

    @Timeout(30)
    @Test
    void messageLength1344bytes() throws Exception
    {
        setProperty(BOOTSTRAP_SERVERS_CONFIG, "localhost:13502");
        setProperty(SECURITY_PROTOCOL_CONFIG, "SSL");
        final Path certificatesPath = Configuration.tryResolveCertificatesDirectory();
        setProperty(SslConfigs.SSL_TRUSTSTORE_LOCATION_CONFIG,
            certificatesPath.resolve("truststore.p12").toString());
        setProperty(SslConfigs.SSL_TRUSTSTORE_TYPE_CONFIG, "PKCS12");
        setProperty(SslConfigs.SSL_TRUSTSTORE_PASSWORD_CONFIG, "truststore");
        setProperty(SslConfigs.SSL_KEYSTORE_LOCATION_CONFIG,
            certificatesPath.resolve("client.keystore").toString());
        setProperty(SslConfigs.SSL_KEYSTORE_TYPE_CONFIG, "PKCS12");
        setProperty(SslConfigs.SSL_KEYSTORE_PASSWORD_CONFIG, "client");

        try
        {
            test(50, 1344, 1);
        }
        finally
        {
            clearProperty(BOOTSTRAP_SERVERS_CONFIG);
            clearProperty(SECURITY_PROTOCOL_CONFIG);
            clearProperty(SslConfigs.SSL_TRUSTSTORE_LOCATION_CONFIG);
            clearProperty(SslConfigs.SSL_TRUSTSTORE_PASSWORD_CONFIG);
            clearProperty(SslConfigs.SSL_KEYSTORE_LOCATION_CONFIG);
            clearProperty(SslConfigs.SSL_KEYSTORE_PASSWORD_CONFIG);
        }
    }

    private void test(final int numberOfMessages, final int messageLength, final int burstSize) throws Exception
    {
        final Configuration configuration = new Configuration.Builder()
            .warmupIterations(0)
            .iterations(1)
            .messageRate(numberOfMessages)
            .batchSize(burstSize)
            .messageLength(messageLength)
            .messageTransceiverClass(InMemoryMessageTransceiver.class) // Not required, created directly
            .outputFileNamePrefix("kafka")
            .build();

        final LoadTestRig loadTestRig = new LoadTestRig(
            configuration,
            SystemNanoClock.INSTANCE,
            new SinglePersistedHistogram(new Histogram(3)),
            KafkaMessageTransceiver::new,
            mock(PrintStream.class));
        loadTestRig.run();
    }
}
