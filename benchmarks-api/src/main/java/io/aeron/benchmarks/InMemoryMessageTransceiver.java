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
package io.aeron.benchmarks;

import org.HdrHistogram.Histogram;
import org.HdrHistogram.ValueRecorder;
import org.agrona.UnsafeApi;
import org.agrona.concurrent.NanoClock;

import static java.lang.Integer.numberOfLeadingZeros;
import static java.util.Arrays.fill;
import static org.agrona.BitUtil.CACHE_LINE_LENGTH;
import static org.agrona.BitUtil.SIZE_OF_LONG;

public final class InMemoryMessageTransceiver extends MessageTransceiver
{
    static final int SIZE = 4096;
    private static final int ARRAY_LONG_BASE_OFFSET = UnsafeApi.arrayBaseOffset(long[].class);
    private static final int MASK = SIZE - 1;
    private static final int SHIFT = 31 - numberOfLeadingZeros(UnsafeApi.arrayIndexScale(long[].class));
    private static final int PADDING = CACHE_LINE_LENGTH / SIZE_OF_LONG - 1;
    private final long[] messages = new long[SIZE];

    private long sendIndex = 0;
    private long receiveIndex = 0;

    public InMemoryMessageTransceiver(final NanoClock nanoClock, final ValueRecorder valueRecorder)
    {
        super(nanoClock, valueRecorder);
    }

    InMemoryMessageTransceiver(final NanoClock clock, final Histogram histogram)
    {
        super(clock, histogram);
    }

    public void init(final Configuration configuration)
    {
        fill(messages, 0L);
    }

    public void destroy()
    {
        fill(messages, 0L);
    }

    public int send(final int numberOfMessages, final int messageLength, final long timestamp, final long checksum)
    {
        final long[] messages = this.messages;
        final long index = sendIndex;
        if (0L != UnsafeApi.getLongVolatile(messages, offset(index + 1 + messageIndexOffset(numberOfMessages))))
        {
            return 0;
        }

        for (int i = numberOfMessages; i > 1; i--)
        {
            UnsafeApi.putLong(messages, offset(index + messageIndexOffset(i)), timestamp);
            UnsafeApi.putLong(messages, offset(index + 1 + messageIndexOffset(i)), checksum);
        }

        UnsafeApi.putLong(messages, offset(index), timestamp);
        UnsafeApi.putLongRelease(messages, offset(index + 1), checksum);

        sendIndex += messageIndexOffset(numberOfMessages + 1);

        return numberOfMessages;
    }

    private static int messageIndexOffset(final int n)
    {
        return (n - 1) * (1 + PADDING);
    }

    public void receive()
    {
        final long checksumOffset = offset(receiveIndex + 1);
        final long[] messages = this.messages;
        final long checksum = UnsafeApi.getLongVolatile(messages, checksumOffset);
        if (0L != checksum)
        {
            final long timestampOffset = offset(receiveIndex);
            final long timestamp = UnsafeApi.getLong(messages, timestampOffset);
            UnsafeApi.putLong(messages, timestampOffset, 0L);
            UnsafeApi.putLongRelease(messages, checksumOffset, 0L);
            onMessageReceived(timestamp, checksum);
            receiveIndex += (1 + PADDING);
        }
    }

    static long offset(final long index)
    {
        return ((index & MASK) << SHIFT) + ARRAY_LONG_BASE_OFFSET;
    }
}
