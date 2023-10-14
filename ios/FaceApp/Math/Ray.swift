//
//  Ray.swift
//  FaceApp
//
//  Created by Bart Trzynadlowski on 10/14/23.
//

import simd

public struct Ray {
    /// Starting point of the ray.
    public var origin: Vector3
    
    /// Normalized vector indicating direction of the ray.
    public var direction: Vector3 {
        get {
            return _direction
        }
        
        set {
            _direction = newValue.normalized
        }
    }
    
    private var _direction: Vector3
    
    public init(origin: Vector3, direction: Vector3) {
        self.origin = origin
        self._direction = direction.normalized
    }
    
    public init(origin: Vector3, through point: Vector3) {
        self.origin = origin
        self._direction = (point - origin).normalized
    }
}
