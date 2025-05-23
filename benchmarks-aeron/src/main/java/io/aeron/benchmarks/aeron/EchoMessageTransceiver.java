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
package io.aeron.benchmarks.aeron;

import io.aeron.Aeron;
import io.aeron.ExclusivePublication;
import io.aeron.FragmentAssembler;
import io.aeron.Subscription;
import io.aeron.driver.MediaDriver;
import io.aeron.logbuffer.BufferClaim;
import org.HdrHistogram.ValueRecorder;
import org.agrona.collections.MutableInteger;
import org.agrona.concurrent.NanoClock;
import org.agrona.concurrent.SystemNanoClock;
import io.aeron.benchmarks.Configuration;
import io.aeron.benchmarks.MessageTransceiver;

import java.nio.file.Path;

import static io.aeron.Aeron.connect;
import static java.nio.ByteOrder.LITTLE_ENDIAN;
import static org.agrona.BitUtil.SIZE_OF_LONG;
import static org.agrona.CloseHelper.closeAll;
import static io.aeron.benchmarks.aeron.AeronUtil.*;

public final class EchoMessageTransceiver extends MessageTransceiver
{
    private final BufferClaim bufferClaim = new BufferClaim();
    private final FragmentAssembler dataHandler = new FragmentAssembler(
        (buffer, offset, length, header) ->
        {
            final long timestamp = buffer.getLong(offset, LITTLE_ENDIAN);
            final long checksum = buffer.getLong(offset + length - SIZE_OF_LONG, LITTLE_ENDIAN);
            onMessageReceived(timestamp, checksum);
        });

    private final MediaDriver mediaDriver;
    private final Aeron aeron;
    private final boolean ownsAeronClient;
    private final MutableInteger receiverIndex = new MutableInteger();
    private Path logsDir;
    ExclusivePublication publication;
    private Subscription subscription;
    private int receiverCount;

    public EchoMessageTransceiver(final NanoClock nanoClock, final ValueRecorder valueRecorder)
    {
        this(nanoClock, valueRecorder, launchEmbeddedMediaDriverIfConfigured(), connect(), true);
    }

    EchoMessageTransceiver(
        final NanoClock nanoClock,
        final ValueRecorder valueRecorder,
        final MediaDriver mediaDriver,
        final Aeron aeron,
        final boolean ownsAeronClient)
    {
        super(nanoClock, valueRecorder);
        this.mediaDriver = mediaDriver;
        this.aeron = aeron;
        this.ownsAeronClient = ownsAeronClient;
    }

    public void init(final Configuration configuration)
    {
        logsDir = configuration.logsDir();
        receiverCount = receiverCount();
        validateMessageLength(configuration.messageLength());
        publication = aeron.addExclusivePublication(destinationChannel(), destinationStreamId());
        subscription = aeron.addSubscription(sourceChannel(), sourceStreamId());

        awaitConnected(
            () -> subscription.isConnected() && subscription.imageCount() == receiverCount &&
            publication.isConnected() && publication.availableWindow() > 0,
            connectionTimeoutNs(),
            SystemNanoClock.INSTANCE);
    }

    public void destroy()
    {
        final String prefix = "echo-client-";
        AeronUtil.dumpAeronStats(
            aeron.context().cncFile(),
            logsDir.resolve(prefix + "aeron-stat.txt"),
            logsDir.resolve(prefix + "errors.txt"));
        closeAll(subscription, publication);

        if (ownsAeronClient)
        {
            closeAll(aeron, mediaDriver);
        }
    }

    public int send(final int numberOfMessages, final int messageLength, final long timestamp, final long checksum)
    {
        return sendMessages(
            publication,
            bufferClaim,
            numberOfMessages,
            messageLength,
            timestamp,
            checksum,
            receiverIndex,
            receiverCount);
    }

    public void receive()
    {
        subscription.poll(dataHandler, FRAGMENT_LIMIT);
    }
}
