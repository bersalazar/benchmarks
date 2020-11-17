/*
 * Copyright 2015-2020 Real Logic Limited.
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
package uk.co.real_logic.benchmarks.aeron.remote;

import io.aeron.ExclusivePublication;
import org.agrona.concurrent.UnsafeBuffer;
import uk.co.real_logic.benchmarks.remote.MessageRecorder;
import uk.co.real_logic.benchmarks.remote.MessageTransceiver;

abstract class EchoMessageTransceiverProducerState extends MessageTransceiver
{

    UnsafeBuffer offerBuffer;
    ExclusivePublication[] publications;
    ExclusivePublication[] passivePublications;
    long keepAliveIntervalNs;
    long timeOfLastKeepAliveNs;
    int sendIndex;

    EchoMessageTransceiverProducerState(final MessageRecorder messageRecorder)
    {
        super(messageRecorder);
    }
}
