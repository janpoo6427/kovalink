import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/vehicle_mesh/builtin_vehicles.dart';
import 'package:kovalink/src/vehicle_mesh/mesh_builder.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh.dart';

/// Share of triangles whose winding agrees with their vertex normals.
double _windingAgreement(VehicleMesh mesh) {
  var good = 0;
  for (var t = 0; t < mesh.triangleCount; t++) {
    P3 at(int k) {
      final v = mesh.indices[t * 3 + k];
      return P3(
        mesh.positions[v * 3],
        mesh.positions[v * 3 + 1],
        mesh.positions[v * 3 + 2],
      );
    }

    final face = (at(1) - at(0)).cross(at(2) - at(0));
    final v = mesh.indices[t * 3];
    final n = P3(
      mesh.normals[v * 3],
      mesh.normals[v * 3 + 1],
      mesh.normals[v * 3 + 2],
    );
    if (face.dot(n) > 0) good++;
  }
  return good / mesh.triangleCount;
}

Set<MeshRole> _roles(VehicleMesh mesh) => {
  for (final m in mesh.materials) m.role,
};

void main() {
  group('built-in vehicles', () {
    for (final (name, mesh, size) in [
      ('suv', BuiltinVehicles.suv, (4.60, 1.86, 1.69)),
      ('sedan', BuiltinVehicles.sedan, (4.60, 1.84, 1.485)),
      ('truck', BuiltinVehicles.truck, (9.0, 2.5, 3.2)),
    ]) {
      test('$name: size, closed winding and unit normals', () {
        expect(mesh.size.$1, closeTo(size.$1, 1e-9));
        expect(mesh.size.$2, closeTo(size.$2, 1e-9));
        expect(mesh.size.$3, closeTo(size.$3, 1e-6));
        final b = mesh.bounds;
        // Decals and mirrors may stick out a little, never a lot.
        expect(b.length, inInclusiveRange(size.$1, size.$1 + 0.1));
        expect(b.height, closeTo(size.$3, 0.02));
        expect(b.minZ, closeTo(0, 1e-6), reason: 'tires touch the ground');
        expect(b.width, inInclusiveRange(size.$2 - 0.05, size.$2 + 0.4));
        expect(_windingAgreement(mesh), greaterThan(0.99));
        for (var i = 0; i < mesh.normals.length; i += 3) {
          final l =
              mesh.normals[i] * mesh.normals[i] +
              mesh.normals[i + 1] * mesh.normals[i + 1] +
              mesh.normals[i + 2] * mesh.normals[i + 2];
          expect(l, closeTo(1, 1e-3));
        }
      });
    }

    test('SUV has the reference details and stays low-poly', () {
      final suv = BuiltinVehicles.suv;
      expect(suv.triangleCount, inInclusiveRange(1500, 5000));
      expect(
        _roles(suv),
        containsAll([
          MeshRole.paint,
          MeshRole.glass,
          MeshRole.tail,
          MeshRole.brake,
          MeshRole.turnLeft,
          MeshRole.turnRight,
          MeshRole.reverse,
          MeshRole.plate,
          MeshRole.tire,
          MeshRole.rim,
          MeshRole.headlight,
        ]),
      );
      // Sunroof, grille and trim decals draw on top of the body.
      final decals = suv.materials.where((m) => m.name.endsWith('_Decal'));
      expect(decals.map((m) => m.name), contains('KL_Sunroof_Decal'));
      expect(decals.every((m) => m.drawsOnTop), isTrue);
    });

    test(
      'rear lamps, plate and wheels sit where the chase camera sees them',
      () {
        final suv = BuiltinVehicles.suv;
        // Every plate/brake vertex of the rear group lies on the rear face.
        for (var t = 0; t < suv.triangleCount; t++) {
          final m = suv.materials[suv.triangleMaterials[t]];
          if (m.role != MeshRole.plate) continue;
          final v = suv.indices[t * 3];
          final x = suv.positions[v * 3];
          if (x < 1) {
            expect(x, lessThan(0), reason: 'rear plate is outside the bumper');
            expect(suv.positions[v * 3 + 1].abs(), lessThanOrEqualTo(0.27));
          }
        }
        // Wheel contact points at both axles.
        final tires = <double>[];
        for (var v = 0; v < suv.vertexCount; v++) {
          if (suv.materials[suv.vertexMaterials[v]].role == MeshRole.tire &&
              suv.positions[v * 3 + 2] < 0.01) {
            tires.add(suv.positions[v * 3]);
          }
        }
        expect(tires.any((x) => (x - 0.95).abs() < 0.05), isTrue);
        expect(tires.any((x) => (x - 3.75).abs() < 0.05), isTrue);
      },
    );
  });

  group('mesh fitting and levels of detail', () {
    VehicleMesh cube({double sx = 2, double sy = 1, double sz = 1}) {
      final b = MeshBuilder();
      b.box(
        const P3(-1, -1, -1),
        P3(-1 + sx, -1 + sy, -1 + sz),
        const MeshMaterial(name: 'm'),
        bottom: true,
      );
      return b.build();
    }

    test('length sets one uniform scale; the rear bumper moves to x = 0', () {
      final fitted = cube(
        sx: 0.04,
        sy: 0.02,
        sz: 0.015,
      ).fittedTo(4.0, 2.0, 1.5);
      final b = fitted.bounds;
      expect(b.minX, closeTo(0, 1e-6));
      expect(b.length, closeTo(4.0, 1e-5));
      expect(b.width, closeTo(2.0, 1e-5));
      expect(b.height, closeTo(1.5, 1e-5));
      expect((b.minY + b.maxY) / 2, closeTo(0, 1e-6));
      expect(fitted.size, (4.0, 2.0, 1.5));
    });

    test(
      'far-off width or height is clamped per axis (authoring mistakes)',
      () {
        // 1:1:1 cube declared as a 4.5 × 1.8 × 1.5 car: width/height would be
        // 150 %+ off with one uniform scale, so those axes are fitted.
        final fitted = cube(sx: 1, sy: 1, sz: 1).fittedTo(4.5, 1.8, 1.5);
        expect(fitted.bounds.width, closeTo(1.8, 1e-5));
        expect(fitted.bounds.height, closeTo(1.5, 1e-5));
      },
    );

    test('vertex clustering respects the budget and keeps materials', () {
      final suv = BuiltinVehicles.suv;
      final small = suv.simplified(600);
      expect(small.triangleCount, lessThanOrEqualTo(600));
      expect(small.triangleCount, greaterThan(100));
      expect(small.materials, same(suv.materials));
      expect(small.bounds.length, closeTo(suv.bounds.length, 0.25));
      expect(identical(suv.simplified(1 << 20), suv), isTrue);
    });

    test('LOD levels shrink with distance', () {
      final set = BuiltinVehicles.suvSet;
      expect(set.lod0.triangleCount, BuiltinVehicles.suv.triangleCount);
      expect(
        set.lod1.triangleCount,
        lessThanOrEqualTo(VehicleMeshSet.lod1Triangles),
      );
      expect(
        set.lod2.triangleCount,
        lessThanOrEqualTo(VehicleMeshSet.lod2Triangles),
      );
      expect(set.lod2.triangleCount, lessThan(set.lod1.triangleCount));
      expect(set.forScreenLength(400), same(set.lod0));
      expect(set.forScreenLength(80), same(set.lod1));
      expect(set.forScreenLength(20), same(set.lod2));
    });

    test('budget caps imported meshes at 20k triangles per vehicle', () {
      // 40 × 40 × 2 grid of quads = 3200 triangles; budget 1000.
      final b = MeshBuilder();
      for (var i = 0; i < 40; i++) {
        for (var j = 0; j < 40; j++) {
          b.poly(
            [
              P3(i * 0.1, j * 0.05 - 1, 1),
              P3(i * 0.1 + 0.1, j * 0.05 - 1, 1),
              P3(i * 0.1 + 0.1, j * 0.05 - 0.95, 1),
              P3(i * 0.1, j * 0.05 - 0.95, 1),
            ],
            const MeshMaterial(name: 'top'),
            const P3(0, 0, 1),
          );
          b.poly(
            [
              P3(i * 0.1, j * 0.05 - 1, 0),
              P3(i * 0.1 + 0.1, j * 0.05 - 1, 0),
              P3(i * 0.1 + 0.1, j * 0.05 - 0.95, 0),
              P3(i * 0.1, j * 0.05 - 0.95, 0),
            ],
            const MeshMaterial(name: 'bottom'),
            const P3(0, 0, -1),
          );
        }
      }
      final set = VehicleMeshSet.fromMesh(
        b.build(),
        length: 4,
        width: 2,
        height: 1,
        budget: 1000,
      );
      expect(set.lod0.triangleCount, lessThanOrEqualTo(1000));
      expect(VehicleMeshSet.renderTriangleBudget, 20000);
    });

    test('colors survive clustering', () {
      final mesh = BuiltinVehicles.sedan;
      final colored = VehicleMesh(
        positions: mesh.positions,
        normals: mesh.normals,
        indices: mesh.indices,
        triangleMaterials: mesh.triangleMaterials,
        materials: mesh.materials,
        colors: Uint32List(mesh.vertexCount)
          ..fillRange(0, mesh.vertexCount, 0xFF336699),
      );
      final small = colored.simplified(300);
      expect(small.colors, isNotNull);
      expect(small.colors!.every((c) => c == 0xFF336699), isTrue);
    });
  });
}
