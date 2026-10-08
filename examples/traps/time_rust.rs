// time trap set for lcc (x30-x31)
//
//   x30 time  (R1, R0) = current Unix time in seconds, high word in R1
//   x31 sleep sleep for R0 milliseconds
//
//   rustc --crate-type staticlib time_rust.rs -o libtime_rust.a
//

use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[repr(C)]
pub struct LccTrapCtx {
    pub memory: *mut u16,
    pub reg: *mut u16,
    pub pc: u16,
    pub cc: *mut u16,
}

#[no_mangle]
pub extern "C" fn lcc_trap_time(ctx: *mut LccTrapCtx) {
    unsafe {
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();

        (*ctx).reg.add(0).write(secs as u16);
        (*ctx).reg.add(1).write((secs >> 16) as u16);
    }
}

#[no_mangle]
pub extern "C" fn lcc_trap_sleep(ctx: *mut LccTrapCtx) {
    unsafe {
        let ms = (*ctx).reg.add(0).read();
        thread::sleep(Duration::from_millis(ms as u64));
    }
}
