//
//  RTPChannel.swift
//  RTP Test
//
//  Created by Jonathan Wight on 6/30/15.
//  Copyright © 2015 3D Robotics Inc. All rights reserved.
//

import CoreMedia

#if os(iOS)
import UIKit
#endif

import SwiftUtilities
import SwiftIO

public protocol RTPContextType: AnyObject {
    func postEvent(event: RTPEvent)
}

public class RTPChannel {

    public private(set) var rtpProcessor: RTPProcessor!
    public private(set) var h264Processor: H264Processor!
    public private(set) var udpChannel: UDPChannel!
    public private(set) var resumed = false
#if os(iOS)
    private var backgroundObserver: AnyObject?
    private var foregroundObserver: AnyObject?
#endif
    private var context: RTPContext! // TODO; Make let
    private let queue = dispatch_queue_create("SwiftRTP.RTPChannel", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0))

    public var handler: (H264Processor.Output throws -> Void)? {
        willSet {
            assert(resumed == false, "It is undefined to set properties while channel is resumed.")
        }
    }
    public var errorHandler: (ErrorType -> Void)? {
        willSet {
            assert(resumed == false, "It is undefined to set properties while channel is resumed.")
        }
    }
    public var eventHandler: (RTPEvent -> Void)? {
        get {
            return context.eventHandler
        }
        set {
            assert(resumed == false, "It is undefined to set properties while channel is resumed.")
            context.eventHandler = newValue
        }
    }
    public init(port: UInt16) throws {

        context = try RTPContext()
        rtpProcessor = RTPProcessor(context: context)
        h264Processor = H264Processor(context: context)

#if os(iOS)
        backgroundObserver = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationDidEnterBackgroundNotification, object: nil, queue: nil) {
            [weak self] (notification) in
            self?.cancel()
        }
        foregroundObserver = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationWillEnterForegroundNotification, object: nil, queue: nil) {
            [weak self] (notification) in
            self?.resume()
        }
#endif

        let address = try Address(address: "0.0.0.0", port: port)

        udpChannel = UDPChannel(label: "RTP", address: address, qos: QOS_CLASS_USER_INTERACTIVE) {
            [weak self] (datagram) in

            guard let strong_self = self else {
                return
            }

            dispatch_async(strong_self.queue) {
                strong_self.processDatagram(datagram)
            }
        }
    }

    deinit {
#if os(iOS)
        if let backgroundObserver = backgroundObserver {
            NSNotificationCenter.defaultCenter().removeObserver(backgroundObserver)
        }
        if let foregroundObserver = foregroundObserver {
            NSNotificationCenter.defaultCenter().removeObserver(foregroundObserver)
        }
#endif
    }

    public func resume() {
        dispatch_sync(queue) {
            [weak self] in

            guard let strong_self = self else {
                return
            }

            if strong_self.resumed == true {
                return
            }
            do {
                try strong_self.udpChannel.resume()
                strong_self.resumed = true
            }
            catch {
                strong_self.errorHandler?(error)
            }
        }
    }

    public func cancel() {
        dispatch_sync(queue) {
            [weak self] in

            guard let strong_self = self else {
                return
            }

            if strong_self.resumed == false {
                return
            }
            do {
                try strong_self.udpChannel.cancel()
                strong_self.resumed = false
            }
            catch {
                strong_self.errorHandler?(error)
            }
        }
    }

    public func processDatagram(datagram: Datagram) {

        if resumed == false {
            return
        }

        postEvent(.PacketReceived)

        do {
            guard let nalus = try rtpProcessor.process(datagram.data) else {
                return
            }

            postEvent(.NALUProduced)

            for nalu in nalus {
                try processNalu(nalu)
            }
        }
        catch {
            postEvent(.ErrorInPipeline)
            errorHandler?(error)
        }
    }


    func processNalu(nalu: H264NALU) throws {
        do {
            guard let output = try h264Processor.process(nalu) else {
                return
            }

            switch output {
                case .FormatDescription:
                    postEvent(.FormatDescriptionProduced)
                case .SampleBuffer:
                    postEvent(.SampleBufferProduced)
            }

            postEvent(.H264FrameProduced)
            try handler?(output)
        }
        catch {
            switch error {
                case RTPError.SkippedFrame:
                    postEvent(.H264FrameSkipped)
                case RTPError.FragmentationUnitError:
                    fallthrough
                default:
                    postEvent(.ErrorInPipeline)
            }
            throw error
        }
    }

    public func postEvent(event: RTPEvent) {
        eventHandler?(event)
    }
}

internal class RTPContext: RTPContextType {

    internal var eventHandler: (RTPEvent -> Void)?

    init() throws {
    }

    internal func postEvent(event: RTPEvent) {
        eventHandler?(event)
    }

}
