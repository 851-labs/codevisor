#import "ChromiumBridge.h"
#include <malloc/malloc.h>
#include <mach/mach.h>

namespace {
malloc_zone_t delegatingZone;
malloc_introspection_t delegatingIntrospection;
malloc_zone_t *systemZone;
}

void CVRegisterChromiumMallocZone(void) {
  malloc_zone_t *purgeableZone = malloc_default_purgeable_zone();
  vm_address_t *zones = nullptr;
  unsigned zoneCount = 0;
  if (malloc_get_all_zones(mach_task_self(), nullptr, &zones, &zoneCount) != KERN_SUCCESS || zoneCount == 0) return;
  systemZone = reinterpret_cast<malloc_zone_t *>(zones[0]);

  delegatingZone.malloc = [](malloc_zone_t *, size_t size) { return systemZone->malloc(systemZone, size); };
  delegatingZone.calloc = [](malloc_zone_t *, size_t count, size_t size) {
    return systemZone->calloc(systemZone, count, size);
  };
  delegatingZone.valloc = [](malloc_zone_t *, size_t size) { return systemZone->valloc(systemZone, size); };
  delegatingZone.realloc = [](malloc_zone_t *, void *pointer, size_t size) {
    return systemZone->realloc(systemZone, pointer, size);
  };
  delegatingZone.batch_malloc = [](malloc_zone_t *, size_t size, void **results, unsigned count) {
    return systemZone->batch_malloc(systemZone, size, results, count);
  };
  delegatingZone.memalign = [](malloc_zone_t *, size_t alignment, size_t size) {
    return systemZone->memalign(systemZone, alignment, size);
  };
  delegatingZone.size = [](malloc_zone_t *, const void *) -> size_t { return 0; };
  delegatingZone.free = [](malloc_zone_t *, void *pointer) { systemZone->free(systemZone, pointer); };
  delegatingZone.free_definite_size = [](malloc_zone_t *, void *pointer, size_t size) {
    systemZone->free_definite_size(systemZone, pointer, size);
  };
  delegatingZone.batch_free = [](malloc_zone_t *, void **pointers, unsigned count) {
    systemZone->batch_free(systemZone, pointers, count);
  };
  if (systemZone->version >= 13 && systemZone->try_free_default) {
    delegatingZone.try_free_default = [](malloc_zone_t *, void *pointer) {
      systemZone->try_free_default(systemZone, pointer);
    };
  }
  delegatingZone.pressure_relief = [](malloc_zone_t *, size_t) -> size_t { return 0; };

  delegatingIntrospection.enumerator = [](task_t, void *, unsigned, vm_address_t, memory_reader_t,
                                          vm_range_recorder_t) -> kern_return_t { return KERN_SUCCESS; };
  delegatingIntrospection.good_size = [](malloc_zone_t *, size_t size) {
    return systemZone->introspect->good_size(systemZone, size);
  };
  delegatingIntrospection.check = [](malloc_zone_t *) -> boolean_t { return true; };
  delegatingIntrospection.print = [](malloc_zone_t *, boolean_t) {};
  delegatingIntrospection.log = [](malloc_zone_t *, void *) {};
  delegatingIntrospection.force_lock = [](malloc_zone_t *) {};
  delegatingIntrospection.force_unlock = [](malloc_zone_t *) {};
  delegatingIntrospection.reinit_lock = [](malloc_zone_t *) {};
  delegatingIntrospection.statistics = [](malloc_zone_t *, malloc_statistics_t *) {};
  delegatingIntrospection.zone_locked = [](malloc_zone_t *) -> boolean_t { return false; };
  delegatingIntrospection.enable_discharge_checking = [](malloc_zone_t *) -> boolean_t { return false; };
  delegatingIntrospection.disable_discharge_checking = [](malloc_zone_t *) {};
  delegatingIntrospection.discharge = [](malloc_zone_t *, void *) {};

  delegatingZone.version = 13;
  delegatingZone.introspect = &delegatingIntrospection;
  delegatingZone.zone_name = "DelegatingDefaultZoneForPartitionAlloc";

  malloc_zone_register(&delegatingZone);
  malloc_zone_unregister(systemZone);
  malloc_zone_register(systemZone);
  malloc_zone_unregister(purgeableZone);
  malloc_zone_register(purgeableZone);
}
