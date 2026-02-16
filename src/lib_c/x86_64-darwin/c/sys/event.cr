require "../time"

lib LibC
  EVFILT_READ  =  -1_i16
  EVFILT_WRITE =  -2_i16
  EVFILT_TIMER =  -7_i16
  EVFILT_USER  = -10_i16

  EV_ADD     = 0x0001_u16
  EV_DELETE  = 0x0002_u16
  EV_ENABLE  = 0x0004_u16
  EV_ONESHOT = 0x0010_u16
  EV_CLEAR   = 0x0020_u16
  EV_EOF     = 0x8000_u16
  EV_ERROR   = 0x4000_u16

  EVFILT_VNODE = -4_i16

  NOTE_NSECONDS = 0x00000004_u32
  NOTE_TRIGGER  = 0x01000000_u32
  NOTE_DELETE   = 0x00000001_u32
  NOTE_WRITE    = 0x00000002_u32
  NOTE_EXTEND   = 0x00000004_u32
  NOTE_ATTRIB   = 0x00000008_u32
  NOTE_LINK     = 0x00000010_u32
  NOTE_RENAME   = 0x00000020_u32
  NOTE_REVOKE   = 0x00000040_u32

  struct Kevent
    ident : SizeT # UintptrT
    filter : Int16
    flags : UInt16
    fflags : UInt32
    data : SSizeT # IntptrT
    udata : Void*
  end

  fun kqueue : Int
  fun kevent(kq : Int, changelist : Kevent*, nchanges : Int, eventlist : Kevent*, nevents : Int, timeout : Timespec*) : Int
end
