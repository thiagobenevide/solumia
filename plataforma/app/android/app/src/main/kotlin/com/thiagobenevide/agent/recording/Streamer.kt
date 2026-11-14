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
) {
    private val encoder: MediaCodec
    val surface: Surface
    private val network: NetworkSink?
    private val recorder: LocalRecorder?
    private val startedAt = SystemClock.elapsedRealtime()
    private val drain: Thread

    val connected get() = network?.connected ?: false
    val fileName get() = recorder?.name

    init {
        val mime = if (hevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        encoder = MediaCodec.createEncoderByType(mime)
        val range = encoder.codecInfo.getCapabilitiesForType(mime).videoCapabilities.bitrateRange
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate.coerceIn(range.lower, range.upper))
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_OPERATING_RATE, fps)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            // one keyframe per second: the PC can join or come back mid-stream
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            if (Build.VERSION.SDK_INT >= 29) setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
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
        val header = "SOLUMIA-CAM 1 $codec ${width}x$height $fps ${if (hlg) 1 else 0}\n"
        network = host?.let { NetworkSink(it, port, header.toByteArray(), ::requestKeyFrame, onWarning) }
        recorder = if (recordLocal) LocalRecorder(context, withAudio, realtimeClock, ::requestKeyFrame, onWarning) else null
        drain = Thread(::drainEncoder, "camera-encoder").apply { start() }
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
) {
    private val queue = LinkedBlockingQueue<ByteArray>(90)
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
            codecHeader?.let { queue.offer(it) }
            needsKeyFrame = false
        }
        if (!queue.offer(data)) {
            // the network fell behind: drop the backlog and restart from the next keyframe
            queue.clear()
            needsKeyFrame = true
            requestKeyFrame()
            onWarning("Slow network: frames dropped (lower the bitrate or use USB)")
        }
    }

    private fun loop() {
        var warned = false
        while (running) {
            var socket: Socket? = null
            try {
                socket = Socket().apply {
                    tcpNoDelay = true
                    sendBufferSize = 4 * 1024 * 1024
                    connect(InetSocketAddress(host, port), 3000)
                }
                val output = BufferedOutputStream(socket.getOutputStream(), 1 shl 20)
                output.write(header)
                output.flush()
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
            val data = queue.poll(500, TimeUnit.MILLISECONDS) ?: continue
            output.write(data)
            if (queue.isEmpty()) output.flush()
            sent.addAndGet(data.size.toLong())
        }
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
    private val realtimeClock: Boolean,
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
    @Volatile private var running = true
    private var audioThread: Thread? = null

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
        if (withAudio) audioThread = Thread(::recordAudio, "camera-audio").apply { start() }
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

    private fun nowUs() =
        if (realtimeClock) SystemClock.elapsedRealtimeNanos() / 1000 else System.nanoTime() / 1000

    @SuppressLint("MissingPermission") // the screen only starts after asking for camera + microphone
    private fun recordAudio() {
        val rate = 48_000
        val channels = AudioFormat.CHANNEL_IN_STEREO
        val minimum = AudioRecord.getMinBufferSize(rate, channels, AudioFormat.ENCODING_PCM_16BIT)
        val record = try {
            AudioRecord(MediaRecorder.AudioSource.CAMCORDER, rate, channels, AudioFormat.ENCODING_PCM_16BIT, minimum * 4)
        } catch (e: Exception) {
            onWarning("Microphone unavailable: ${e.message}")
            return
        }
        val aac = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 2).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 256_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, minimum * 4)
        }
        aac.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        aac.start()
        record.startRecording()
        try {
            pumpAudio(record, aac, ByteArray(minimum), rate)
        } finally {
            record.stop()
            record.release()
            aac.stop()
            aac.release()
        }
    }

    private fun pumpAudio(record: AudioRecord, aac: MediaCodec, pcm: ByteArray, rate: Int) {
        val info = MediaCodec.BufferInfo()
        var finished = false
        while (!finished) {
            val input = aac.dequeueInputBuffer(10_000)
            if (input >= 0) {
                val read = record.read(pcm, 0, pcm.size)
                // pts of the block start: now minus the duration just read (16 bits, 2 channels)
                val pts = nowUs() - (read.coerceAtLeast(0) / 4) * 1_000_000L / rate
                val buffer = aac.getInputBuffer(input)!!
                buffer.clear()
                if (read > 0) buffer.put(pcm, 0, read)
                val flags = if (running) 0 else MediaCodec.BUFFER_FLAG_END_OF_STREAM
                aac.queueInputBuffer(input, 0, read.coerceAtLeast(0), pts, flags)
            }
            finished = drainAudio(aac, info)
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
        running = false
        audioThread?.join(3000)
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
