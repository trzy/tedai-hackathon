//
//  simd_float3+Extensions.swift
//  FaceApp
//
//  Created by Bart Trzynadlowski on 10/14/23.
//

import simd

extension simd_float3 {
    public static var forward: simd_float3 {
        return simd_float3(x: 0, y: 0, z: 1)
    }
    
    public static var up: simd_float3 {
        return simd_float3(x: 0, y: 1, z: 0)
    }
    
    public static var right: simd_float3 {
        return simd_float3(x: 1, y: 0, z: 0)
    }

    public var normalized: simd_float3 {
        return simd_normalize(self)
    }
}
