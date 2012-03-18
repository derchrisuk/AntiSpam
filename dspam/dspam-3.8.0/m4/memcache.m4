# $Id$
# m4/memcache.m4
# Adam Thomason <athomason@sixapart.com>
#
#   DS_MEMCACHE()
#
#   Use libmemcached for caching database lookups.
#
AC_DEFUN([DS_MEMCACHE],
[
  AC_ARG_ENABLE(memcache,
      [AS_HELP_STRING(--enable-memcache,
                        Enable database query result caching via libmemcached
                      )])
  AC_MSG_CHECKING([whether to enable memcached support])
  case x"$enable_memcache" in
      xyes)   # memcache support enabled explicity
              ;;
      xno)    # memcache support disabled explicity
              ;;
      x)      # memcache support disabled by default
              enable_memcache=no
              ;;
      *)      AC_MSG_ERROR([unexpected value $enable_memcache for --{enable,disable}-memcache configure option])
              ;;
  esac
  if test x"$enable_memcache" != xyes
  then
      enable_memcache=no
  else
      AC_DEFINE(USE_MEMCACHE, 1, [Defined if memcache support is enabled])

      PKG_CHECK_MODULES(DEPS, libmemcached >= 0.8.0) AC_SUBST(DEPS_CFLAGS) AC_SUBST(DEPS_LIBS)
  fi
  AC_MSG_RESULT([$enable_memcache])
])
