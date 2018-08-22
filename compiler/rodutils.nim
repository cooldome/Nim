#
#
#           The Nim Compiler
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Serialization utilities for the compiler.
import strutils, math

# bcc doesn't have C99 functions
when defined(windows) and defined(bcc):
  {.emit: """#if defined(_MSC_VER) && _MSC_VER < 1900
  #include <stdarg.h>
  static int c99_vsnprintf(char *outBuf, size_t size, const char *format, va_list ap) {
    int count = -1;
    if (size != 0) count = _vsnprintf_s(outBuf, size, _TRUNCATE, format, ap);
    if (count == -1) count = _vscprintf(format, ap);
    return count;
  }
  int snprintf(char *outBuf, size_t size, const char *format, ...) {
    int count;
    va_list ap;
    va_start(ap, format);
    count = c99_vsnprintf(outBuf, size, format, ap);
    va_end(ap);
    return count;
  }
  #endif
  """.}

proc c_snprintf(s: cstring; n:uint; frmt: cstring): cint {.importc: "snprintf", header: "<stdio.h>", nodecl, varargs.}

proc toStrMaxPrecision*(f: BiggestFloat, literalPostfix = ""): string =
  case classify(f)
  of fcNaN:
    result = "NAN"
  of fcNegZero:
    result = "-0.0" & literalPostfix
  of fcZero:
    result = "0.0" & literalPostfix
  of fcInf:
    result = "INF"
  of fcNegInf:
    result = "-INF"
  else:
    when defined(nimNoArrayToCstringConversion):
      result = newString(81)
      let n = c_snprintf(result.cstring, result.len.uint, "%#.16e%s", f, literalPostfix.cstring)
      setLen(result, n)
    else:
      var buf: array[0..80, char]
      discard c_snprintf(buf.cstring, buf.len.uint, "%#.16e%s", f, literalPostfix.cstring)
      result = $buf.cstring

proc encodeStr*(s: string, result: var string) =
  for i in countup(0, len(s) - 1):
    case s[i]
    of 'a'..'z', 'A'..'Z', '0'..'9', '_': add(result, s[i])
    else: add(result, '\\' & toHex(ord(s[i]), 2))

proc hexChar(c: char, xi: var int) =
  case c
  of '0'..'9': xi = (xi shl 4) or (ord(c) - ord('0'))
  of 'a'..'f': xi = (xi shl 4) or (ord(c) - ord('a') + 10)
  of 'A'..'F': xi = (xi shl 4) or (ord(c) - ord('A') + 10)
  else: discard

proc decodeStr*(s: cstring, pos: var int): string =
  var i = pos
  result = ""
  while true:
    case s[i]
    of '\\':
      inc(i, 3)
      var xi = 0
      hexChar(s[i-2], xi)
      hexChar(s[i-1], xi)
      add(result, chr(xi))
    of 'a'..'z', 'A'..'Z', '0'..'9', '_':
      add(result, s[i])
      inc(i)
    else: break
  pos = i

const
  chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

{.push overflowChecks: off.}

# since negative numbers require a leading '-' they use up 1 byte. Thus we
# subtract/add `vintDelta` here to save space for small negative numbers
# which are common in ROD files:
const
  vintDelta = 5

template encodeIntImpl(self) =
  var d: char
  var v = x
  var rem = v mod 190
  if rem < 0:
    add(result, '-')
    v = - (v div 190)
    rem = - rem
  else:
    v = v div 190
  var idx = int(rem)
  if idx < 62: d = chars[idx]
  else: d = chr(idx - 62 + 128)
  if v != 0: self(v, result)
  add(result, d)

proc encodeVBiggestIntAux(x: BiggestInt, result: var string) =
  ## encode a biggest int as a variable length base 190 int.
  encodeIntImpl(encodeVBiggestIntAux)

proc encodeVBiggestInt*(x: BiggestInt, result: var string) =
  ## encode a biggest int as a variable length base 190 int.
  encodeVBiggestIntAux(x +% vintDelta, result)
  #  encodeIntImpl(encodeVBiggestInt)

proc encodeVIntAux(x: int, result: var string) =
  ## encode an int as a variable length base 190 int.
  encodeIntImpl(encodeVIntAux)

proc encodeVInt*(x: int, result: var string) =
  ## encode an int as a variable length base 190 int.
  encodeVIntAux(x +% vintDelta, result)

template decodeIntImpl() =
  var i = pos
  var sign = - 1
  assert(s[i] in {'a'..'z', 'A'..'Z', '0'..'9', '-', '\x80'..'\xFF'})
  if s[i] == '-':
    inc(i)
    sign = 1
  result = 0
  while true:
    case s[i]
    of '0'..'9': result = result * 190 - (ord(s[i]) - ord('0'))
    of 'a'..'z': result = result * 190 - (ord(s[i]) - ord('a') + 10)
    of 'A'..'Z': result = result * 190 - (ord(s[i]) - ord('A') + 36)
    of '\x80'..'\xFF': result = result * 190 - (ord(s[i]) - 128 + 62)
    else: break
    inc(i)
  result = result * sign -% vintDelta
  pos = i

proc decodeVInt*(s: cstring, pos: var int): int =
  decodeIntImpl()

proc decodeVBiggestInt*(s: cstring, pos: var int): BiggestInt =
  decodeIntImpl()

{.pop.}

iterator decodeVIntArray*(s: cstring): int =
  var i = 0
  while s[i] != '\0':
    yield decodeVInt(s, i)
    if s[i] == ' ': inc i

iterator decodeStrArray*(s: cstring): string =
  var i = 0
  while s[i] != '\0':
    yield decodeStr(s, i)
    if s[i] == ' ': inc i
