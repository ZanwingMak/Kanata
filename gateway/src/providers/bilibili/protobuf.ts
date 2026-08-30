/**
 * 最小 protobuf 读取器，仅覆盖 B 站弹幕分片所需的字段类型。
 * 不引入 protobufjs 依赖，也避免 .proto 编译步骤（CLAUDE.md 第 4 条：保持简洁）。
 *
 * 目标消息：bilibili.community.service.dm.v1.DmSegMobileReply
 *   DmSegMobileReply { repeated DanmakuElem elems = 1; }
 */

/** protobuf 线类型 */
const WIRE_VARINT = 0;
const WIRE_FIXED64 = 1;
const WIRE_LENGTH = 2;
const WIRE_FIXED32 = 5;

/** B 站单条弹幕的原始字段 */
export interface BiliDanmakuElem {
  id: bigint;
  /** 时间轴位置，毫秒 */
  progress: number;
  mode: number;
  fontsize: number;
  color: number;
  midHash: string;
  content: string;
  /** 发送时间，Unix 秒 */
  ctime: number;
  weight: number;
  pool: number;
}

/** 顺序读取字节流的游标 */
class Reader {
  private offset = 0;

  constructor(private readonly buf: Uint8Array) {}

  get done(): boolean {
    return this.offset >= this.buf.length;
  }

  /** 读一个 varint，返回 bigint 以容纳 int64 字段 */
  readVarint(): bigint {
    let result = 0n;
    let shift = 0n;
    while (this.offset < this.buf.length) {
      const byte = this.buf[this.offset++] as number;
      result |= BigInt(byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) break;
      shift += 7n;
    }
    return result;
  }

  /** 读一段长度前缀的字节 */
  readBytes(): Uint8Array {
    const length = Number(this.readVarint());
    const start = this.offset;
    this.offset = Math.min(start + length, this.buf.length);
    return this.buf.subarray(start, this.offset);
  }

  /** 跳过指定线类型的一个字段值，用于忽略未知字段 */
  skip(wireType: number): void {
    switch (wireType) {
      case WIRE_VARINT:
        this.readVarint();
        break;
      case WIRE_FIXED64:
        this.offset += 8;
        break;
      case WIRE_LENGTH:
        this.readBytes();
        break;
      case WIRE_FIXED32:
        this.offset += 4;
        break;
      default:
        // 未知线类型无法安全跳过，直接结束解析
        this.offset = this.buf.length;
    }
  }
}

const decoder = new TextDecoder('utf-8');

/** 解析单条 DanmakuElem */
function parseElem(bytes: Uint8Array): BiliDanmakuElem {
  const reader = new Reader(bytes);
  const elem: BiliDanmakuElem = {
    id: 0n,
    progress: 0,
    mode: 1,
    fontsize: 25,
    color: 16777215,
    midHash: '',
    content: '',
    ctime: 0,
    weight: 0,
    pool: 0,
  };
  while (!reader.done) {
    const tag = Number(reader.readVarint());
    const field = tag >> 3;
    const wireType = tag & 0x07;
    switch (field) {
      case 1:
        elem.id = reader.readVarint();
        break;
      case 2:
        elem.progress = Number(reader.readVarint());
        break;
      case 3:
        elem.mode = Number(reader.readVarint());
        break;
      case 4:
        elem.fontsize = Number(reader.readVarint());
        break;
      case 5:
        elem.color = Number(reader.readVarint());
        break;
      case 6:
        elem.midHash = decoder.decode(reader.readBytes());
        break;
      case 7:
        elem.content = decoder.decode(reader.readBytes());
        break;
      case 8:
        elem.ctime = Number(reader.readVarint());
        break;
      case 9:
        elem.weight = Number(reader.readVarint());
        break;
      case 11:
        elem.pool = Number(reader.readVarint());
        break;
      default:
        reader.skip(wireType);
    }
  }
  return elem;
}

/**
 * 解析一个弹幕分片，返回其中的全部弹幕条目。
 * @param buf seg.so 接口返回的二进制体
 */
export function parseDmSegment(buf: Uint8Array): BiliDanmakuElem[] {
  const reader = new Reader(buf);
  const elems: BiliDanmakuElem[] = [];
  while (!reader.done) {
    const tag = Number(reader.readVarint());
    const field = tag >> 3;
    const wireType = tag & 0x07;
    if (field === 1 && wireType === WIRE_LENGTH) {
      elems.push(parseElem(reader.readBytes()));
    } else {
      reader.skip(wireType);
    }
  }
  return elems;
}
