package com.thiagobenevide.agent.recording

import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.MediaStore
import android.view.Surface
import java.io.BufferedOutputStream
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * One video encoder (HEVC or H.264, surface input) and two outputs of the SAME stream, no re-encoding:
 * [NetworkSink] sends Annex-B over TCP to the PC receiver and [LocalRecorder] writes the original MP4
 * with audio on the phone. TCP protocol: one header line
 * `SOLUMIA-CAM 1 <hevc|avc> <W>x<H> <fps> <hlg 0|1>\n` followed by the raw stream.
 */
class Streamer(
    context: Context,
    width: Int,
    height: Int,
    fps: Int,
    hevc: Boolean,
    bitrate: Int,
    hlg: Boolean,
    host: String?,
    port: Int,
    recordLocal: Boolean,
    withAudio: Boolean,
    realtimeClock: Boolean,
    private val onWarning: (String) -> Unit,
    onRemote: (String) -> Unit = {},
) {
    private val encoder: MediaCodec
    val surface: Surface
    private val network: NetworkSink?
    private val recorder: LocalRecorder?
    private val startedAt = SystemClock.elapsedRealtime()
    private val drain: Thread

    private val realtime = realtimeClock
    @Volatile private var capturing = true
    private var audioThread: Thread? = null

    val connected get() = network?.connected ?: false
    val fileName get() = recorder?.name

    init {
        val mime = if (hevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        encoder = MediaCodec.createEncoderByType(mime)
        val video = encoder.codecInfo.getCapabilitiesForType(mime).videoCapabilities
        val range = video.bitrateRange
        if (!video.areSizeAndRateSupported(width, height, fps.toDouble())) {
            onWarning("The encoder does not guarantee ${width}x$height at $fps fps: frames may drop")
        }
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate.coerceIn(range.lower, range.upper))
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_OPERATING_RATE, fps)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            // one keyframe per second: the PC can join or come back mid-stream
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            if (Build.VERSION.SDK_INT >= 29) {
                setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
                // live preview: each frame leaves the encoder as soon as it is ready (no reordering)
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LATENCY, 1)
            if (hlg && hevc) {
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10)
                setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT2020)
                setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_HLG)
                setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            }
        }
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = encoder.createInputSurface()
        encoder.start()

        val codec = if (hevc) "hevc" else "avc"
        // framed stream (video + lossless PCM + camera state) and remote control, see protocol.dart
        val audioToken = if (withAudio) " pcm${AUDIO_RATE}x$AUDIO_CHANNELS" else ""
        val header = "SOLUMIA-CAM 1 $codec ${width}x$height $fps ${if (hlg) 1 else 0}$audioToken ctl\n"
        network = host?.let { NetworkSink(it, port, header.toByteArray(), ::requestKeyFrame, onWarning, onRemote) }
        recorder = if (recordLocal) LocalRecorder(context, withAudio, ::requestKeyFrame, onWarning) else null
        drain = Thread(::drainEncoder, "camera-encoder").apply { start() }
        if (withAudio) audioThread = Thread(::captureAudio, "camera-audio").apply { start() }
    }

    /** Camera clock (realtime or monotonic), so audio and video share one timeline. */
    private fun nowUs() =
        if (realtime) SystemClock.elapsedRealtimeNanos() / 1000 else System.nanoTime() / 1000

    /** One microphone read feeds both the phone MP4 (AAC) and the PC (raw PCM, no quality loss). */
    @SuppressLint("MissingPermission") // the screen only starts after asking for camera + microphone
    private fun captureAudio() {
        val channels = AudioFormat.CHANNEL_IN_STEREO
        val minimum = AudioRecord.getMinBufferSize(AUDIO_RATE, channels, AudioFormat.ENCODING_PCM_16BIT)
        val record = try {
            AudioRecord(MediaRecorder.AudioSource.CAMCORDER, AUDIO_RATE, channels, AudioFormat.ENCODING_PCM_16BIT, minimum * 4)
        } catch (e: Exception) {
            onWarning("Microphone unavailable: ${e.message}")
            recorder?.endAudio()
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            // another app holds the microphone: the constructor does not throw, it just stays unusable
            onWarning("Microphone unavailable (in use by another app?)")
            record.release()
            recorder?.endAudio()
            return
        }
        val pcm = ByteArray(minimum)
        record.startRecording()
        try {
            while (capturing) {
                val read = record.read(pcm, 0, pcm.size)
                if (read <= 0) continue
                // pts of the block start: now minus the duration just read (16 bits, 2 channels)
                val pts = nowUs() - (read / 4) * 1_000_000L / AUDIO_RATE
                recorder?.audio(pcm, read, pts)
                network?.sendAudio(pcm.copyOf(read))
            }
        } finally {
            record.stop()
            record.release()
            recorder?.endAudio()
        }
    }

    private fun drainEncoder() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = try {
                encoder.dequeueOutputBuffer(info, 10_000)
            } catch (e: IllegalStateException) {
                break
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                recorder?.videoFormat(encoder.outputFormat)
                continue
            }
            if (index < 0) continue
            val buffer = encoder.getOutputBuffer(index)
            if (buffer != null && info.size > 0) handleOutput(buffer, info)
            encoder.releaseOutputBuffer(index, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
        }
    }

    private fun handleOutput(buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        val data = ByteArray(info.size)
        buffer.get(data)
        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
            network?.codecHeader = data
            return
        }
        val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        network?.send(data, key)
        recorder?.video(data, info.presentationTimeUs, key)
    }

    private fun requestKeyFrame() {
        try {
            encoder.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (_: IllegalStateException) {
        }
    }

    fun mbpsLastSecond() = network?.mbpsLastSecond() ?: 0.0

    /** Camera state (JSON) for the PC; sent now and again after every reconnection. */
    fun sendControl(json: String) {
        network?.sendControl(json.toByteArray())
    }

    fun seconds() = ((SystemClock.elapsedRealtime() - startedAt) / 1000).toInt()

    /** Closes everything and returns the local MP4 name (or null). Blocks: call off the main thread. */
    fun stop(): String? {
        try {
            encoder.signalEndOfInputStream()
        } catch (_: IllegalStateException) {
        }
        drain.join(3000)
        try {
            encoder.stop()
        } catch (_: IllegalStateException) {
        }
        encoder.release()
        surface.release()
        capturing = false
        audioThread?.join(3000)
        network?.stop()
        return recorder?.stop()
    }
}

/** Sends the stream to the PC; reconnects on its own and, after reconnecting, restarts at a keyframe. */
private class NetworkSink(
    private val host: String,
    private val port: Int,
    private val header: ByteArray,
    private val requestKeyFrame: () -> Unit,
    private val onWarning: (String) -> Unit,
    private val onRemote: (String) -> Unit,
) {
    private class Packet(val type: Byte, val data: ByteArray, val at: Long = SystemClock.elapsedRealtime())

    // ~3 s of video plus the audio blocks (~50/s) in between
    private val queue = LinkedBlockingQueue<Packet>(400)
    @Volatile var connected = false
    @Volatile var codecHeader: ByteArray? = null
    @Volatile private var running = true
    @Volatile private var needsKeyFrame = true
    private val sent = AtomicLong(0)
    private var lastReadAt = SystemClock.elapsedRealtime()
    private var lastTotal = 0L
    private val thread = Thread(::loop, "camera-network").apply { start() }

    fun send(data: ByteArray, key: Boolean) {
        if (!connected) return
        if (needsKeyFrame) {
            if (!key) return
            codecHeader?.let { queue.offer(Packet(VIDEO, it)) }
            needsKeyFrame = false
        }
        if (!queue.offer(Packet(VIDEO, data))) {
            // the network fell behind: drop the backlog and restart from the next keyframe
            queue.clear()
            control?.let { queue.offer(Packet(CONTROL, it)) }
            needsKeyFrame = true
            requestKeyFrame()
            onWarning("Slow network: frames dropped (lower the bitrate or use USB)")
        }
    }

    /** Last camera state: the PC gets it right after connecting, before any video. */
    @Volatile private var control: ByteArray? = null

    fun sendControl(data: ByteArray) {
        control = data
        if (connected) queue.offer(Packet(CONTROL, data))
    }

    /** Commands from the PC (one JSON per line) on the same socket; ends when the socket closes. */
    private fun readCommands(socket: Socket) {
        try {
            val reader = socket.getInputStream().bufferedReader()
            while (running) {
                val line = reader.readLine() ?: break
                if (line.isNotBlank()) onRemote(line)
            }
        } catch (_: Exception) {
            // socket closed: the main loop reconnects
        }
    }

    /** Audio is tiny (1.5 Mb/s): sent only once video is flowing, never the reason for a drop. */
    fun sendAudio(data: ByteArray) {
        if (!connected || needsKeyFrame) return
        queue.offer(Packet(AUDIO, data))
    }

    private fun loop() {
        var warned = false
        while (running) {
            var socket: Socket? = null
            try {
                // built outside apply: inside it `port` would be Socket.getPort(), 0 before connecting
                val address = InetSocketAddress(host, port)
                socket = Socket().apply {
                    tcpNoDelay = true
                    // ~80 ms at 100 Mb/s: a bigger buffer only hides a slow network as delay
                    sendBufferSize = 1024 * 1024
                    connect(address, 3000)
                }
                val output = BufferedOutputStream(socket.getOutputStream(), 1 shl 20)
                output.write(header)
                control?.let {
                    writeFrameHeader(output, Packet(CONTROL, it))
                    output.write(it)
                }
                output.flush()
                val opened = socket
                Thread({ readCommands(opened) }, "camera-commands").start()
                queue.clear()
                needsKeyFrame = true
                connected = true
                warned = false
                requestKeyFrame()
                pump(output)
            } catch (e: Exception) {
                if (running && !warned) {
                    onWarning("No connection to $host:$port (${e.message}); retrying")
                    warned = true
                }
            } finally {
                connected = false
                try {
                    socket?.close()
                } catch (_: Exception) {
                }
            }
            if (running) {
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                }
            }
        }
    }

    private fun pump(output: BufferedOutputStream) {
        while (running) {
            val packet = queue.poll(500, TimeUnit.MILLISECONDS) ?: continue
            if (packet.type == VIDEO && SystemClock.elapsedRealtime() - packet.at > MAX_LAG_MS) {
                // the network fell behind: skip to the next keyframe instead of keeping the delay forever
                queue.clear()
                control?.let { queue.offer(Packet(CONTROL, it)) }
                needsKeyFrame = true
                requestKeyFrame()
                onWarning("Slow network: skipped ahead to stay live (lower the bitrate or use USB)")
                continue
            }
            writeFrameHeader(output, packet)
            output.write(packet.data)
            if (queue.isEmpty()) output.flush()
            sent.addAndGet(packet.data.size.toLong())
        }
    }

    private fun writeFrameHeader(output: BufferedOutputStream, packet: Packet) {
        val size = packet.data.size
        output.write(packet.type.toInt())
        output.write(size ushr 24)
        output.write(size ushr 16)
        output.write(size ushr 8)
        output.write(size)
    }

    fun mbpsLastSecond(): Double {
        val now = SystemClock.elapsedRealtime()
        val total = sent.get()
        val elapsed = (now - lastReadAt).coerceAtLeast(1)
        val mbps = (total - lastTotal) * 8.0 / 1000.0 / elapsed
        lastReadAt = now
        lastTotal = total
        return mbps
    }

    fun stop() {
        running = false
        thread.interrupt()
        thread.join(2000)
    }
}

/**
 * Original MP4 on the phone (Movies/Solumia), with the encoder video and the microphone AAC audio.
 * Both tracks use the camera clock (realtime or monotonic) so they stay in sync.
 */
private class LocalRecorder(
    context: Context,
    private val withAudio: Boolean,
    private val requestKeyFrame: () -> Unit,
    private val onWarning: (String) -> Unit,
) {
    val name = "solumia_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + ".mp4"
    private val resolver = context.contentResolver
    private var uri: Uri? = null
    private val descriptor: ParcelFileDescriptor?
    private val muxer: MediaMuxer
    private val lock = Object()
    private var videoTrack = -1
    private var audioTrack = -1
    private var started = false
    private var videoBegun = false
    private var lastAudioUs = 0L

    init {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, name)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Solumia")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            descriptor = resolver.openFileDescriptor(uri!!, "rw")
            muxer = MediaMuxer(descriptor!!.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } else {
            val folder = File(context.getExternalFilesDir(Environment.DIRECTORY_MOVIES), "Solumia").apply { mkdirs() }
            descriptor = null
            muxer = MediaMuxer(File(folder, name).absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        }
    }

    fun videoFormat(format: MediaFormat) = synchronized(lock) {
        if (videoTrack < 0) {
            videoTrack = muxer.addTrack(format)
            startIfReady()
        }
    }

    private fun audioFormat(format: MediaFormat) = synchronized(lock) {
        if (audioTrack < 0) {
            audioTrack = muxer.addTrack(format)
            startIfReady()
        }
    }

    private fun startIfReady() {
        if (started || videoTrack < 0 || (withAudio && audioTrack < 0)) return
        muxer.start()
        started = true
        requestKeyFrame()
    }

    fun video(data: ByteArray, ptsUs: Long, key: Boolean) = synchronized(lock) {
        if (!started) return
        if (!videoBegun) {
            if (!key) return
            videoBegun = true
        }
        val info = MediaCodec.BufferInfo().apply {
            set(0, data.size, ptsUs, if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
        }
        muxer.writeSampleData(videoTrack, ByteBuffer.wrap(data), info)
    }

    private val aac: MediaCodec? = if (withAudio) createAac() else null
    private val aacInfo = MediaCodec.BufferInfo()

    private fun createAac(): MediaCodec {
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, AUDIO_RATE, AUDIO_CHANNELS).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 320_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 64 * 1024)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        return codec
    }

    /** PCM block from the shared capture (audio thread). */
    fun audio(pcm: ByteArray, size: Int, ptsUs: Long) {
        val codec = aac ?: return
        var offset = 0
        while (offset < size) {
            val input = codec.dequeueInputBuffer(10_000)
            if (input < 0) {
                drainAudio(codec, aacInfo)
                continue
            }
            val buffer = codec.getInputBuffer(input)!!
            buffer.clear()
            val chunk = minOf(buffer.remaining(), size - offset)
            buffer.put(pcm, offset, chunk)
            val pts = ptsUs + (offset / 4) * 1_000_000L / AUDIO_RATE
            codec.queueInputBuffer(input, 0, chunk, pts, 0)
            offset += chunk
        }
        drainAudio(codec, aacInfo)
    }

    /** End of the microphone (audio thread): flushes and releases the AAC encoder. */
    fun endAudio() {
        val codec = aac ?: return
        try {
            val input = codec.dequeueInputBuffer(100_000)
            if (input >= 0) codec.queueInputBuffer(input, 0, 0, lastAudioUs + 1, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            var finished = false
            var tries = 0
            while (!finished && tries < 100) {
                finished = drainAudio(codec, aacInfo)
                tries++
                if (!finished) Thread.sleep(10)
            }
        } catch (_: Exception) {
        } finally {
            codec.stop()
            codec.release()
        }
    }

    /** Writes the encoded audio; returns true at the end of the stream. */
    private fun drainAudio(aac: MediaCodec, info: MediaCodec.BufferInfo): Boolean {
        var finished = false
        while (true) {
            val output = aac.dequeueOutputBuffer(info, 0)
            if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                audioFormat(aac.outputFormat)
                continue
            }
            if (output < 0) break
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) finished = true
            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                writeAudio(aac.getOutputBuffer(output)!!, info)
            }
            aac.releaseOutputBuffer(output, false)
        }
        return finished
    }

    private fun writeAudio(buffer: ByteBuffer, info: MediaCodec.BufferInfo) = synchronized(lock) {
        // audio only after the first video frame, and always increasing
        if (started && videoBegun && info.presentationTimeUs > lastAudioUs) {
            lastAudioUs = info.presentationTimeUs
            muxer.writeSampleData(audioTrack, buffer, info)
        }
    }

    fun stop(): String? {
        synchronized(lock) {
            try {
                if (started) muxer.stop()
            } catch (e: Exception) {
                onWarning("Local MP4 may be incomplete: ${e.message}")
            }
            muxer.release()
        }
        descriptor?.close()
        uri?.let {
            if (started) {
                resolver.update(it, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
            } else {
                resolver.delete(it, null, null)
            }
        }
        return if (started) name else null
    }
}

private const val AUDIO_RATE = 48_000
private const val AUDIO_CHANNELS = 2
private const val VIDEO: Byte = 0x56 // 'V'
private const val AUDIO: Byte = 0x41 // 'A'
private const val CONTROL: Byte = 0x43 // 'C'
/** Oldest a packet may be when it leaves: above this the preview would lag behind the speaker. */
private const val MAX_LAG_MS = 400L
