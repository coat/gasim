// What the page keeps in the browser between visits, in IndexedDB. Each
// call opens the database, which is cheap, and fails quietly as null where
// storage is blocked, such as in some private windows.

const name = 'gasim';
const store = 'files';

function open() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(store);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function transact(mode, f) {
  const db = await open();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(store, mode);
      const request = f(tx.objectStore(store));
      tx.oncomplete = () => resolve(request.result);
      tx.onerror = () => reject(tx.error);
    });
  } finally {
    db.close();
  }
}

/** The value kept under `key`, or null. */
export async function get(key) {
  try {
    return (await transact('readonly', (s) => s.get(key))) ?? null;
  } catch {
    return null;
  }
}

/** Keeps `value` under `key`; returns whether it could. */
export async function put(key, value) {
  try {
    await transact('readwrite', (s) => s.put(value, key));
    return true;
  } catch {
    return false;
  }
}

export async function remove(key) {
  try {
    await transact('readwrite', (s) => s.delete(key));
  } catch {
    // nothing kept, then
  }
}
