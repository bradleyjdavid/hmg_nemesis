/* Host stand-in for bionic's <sys/system_properties.h>, so the native CLI can
 * be built with the host compiler for tests. Every property reads as unset,
 * which the CLI treats as "Android framework not up". */
#ifndef NEMESIS_HOST_SYSTEM_PROPERTIES_H
#define NEMESIS_HOST_SYSTEM_PROPERTIES_H

#define PROP_VALUE_MAX 92

static inline int __system_property_get(const char *name, char *value) {
    (void)name;
    value[0] = 0;
    return 0;
}

static inline int __system_property_set(const char *name, const char *value) {
    (void)name;
    (void)value;
    return 0;
}

#endif
