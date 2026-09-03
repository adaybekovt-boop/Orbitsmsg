'use strict'

/**
 * Node vs official Bare module map. Production Bare loads holepunch
 * `bare-*` packages from the local node_modules tree. Node CI keeps
 * `node:*` builtins. Nothing here fetches remote JS.
 */

const isBare = typeof Bare !== 'undefined'

function load(nodeName, bareName) {
  if (isBare) return require(bareName)
  return require(nodeName)
}

const fs = load('node:fs', 'bare-fs')
const os = load('node:os', 'bare-os')
const path = load('node:path', 'bare-path')
const crypto = load('node:crypto', 'bare-crypto')
const net = load('node:net', 'bare-net')
const events = load('node:events', 'bare-events')
const proc = isBare ? require('bare-process') : process

function ipcChannel() {
  if (typeof BareKit !== 'undefined' && BareKit && BareKit.IPC && BareKit.IPC.write) {
    return {
      kind: 'barekit',
      onData(fn) {
        if (typeof BareKit.IPC.on === 'function') BareKit.IPC.on('data', fn)
        else if (typeof BareKit.IPC.readable === 'function') {
          BareKit.IPC.readable(() => {
            const chunk = BareKit.IPC.read()
            if (chunk) fn(chunk)
          })
        }
      },
      write(buf) {
        BareKit.IPC.write(buf)
      },
    }
  }
  if (proc.stdin && proc.stdout) {
    return {
      kind: 'stdio',
      onData(fn) {
        proc.stdin.on('data', fn)
      },
      write(buf) {
        proc.stdout.write(buf)
      },
    }
  }
  throw new Error('BARE_RUNTIME_MISSING: no BareKit.IPC or stdio')
}

module.exports = {
  isBare,
  fs,
  os,
  path,
  crypto,
  net,
  events,
  process: proc,
  ipcChannel,
}
