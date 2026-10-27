import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

// Folder v1: offer(isDirectory, entryCount), ordered entry records + raw chunks, end.
export class FolderEntry {
  path: string = '';
  directory: boolean = false;
  size: number = 0;
}
export function validFolderPath(path: string): boolean {
  const parts = path.split('/');
  return path.length > 0 && new util.TextEncoder().encodeInto(path).length <= 4096 && parts.length <= 128 &&
    !/[\\\x00-\x1f\x7f-\x9f]/.test(path) && parts.every((part: string) => part.length > 0 && part !== '.' && part !== '..');
}
export class FolderPlan {
  entries: FolderEntry[] = [];
  bytes: number = 0;
  constructor(root: string) {
    const stat = fs.lstatSync(root);
    if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error('请选择普通文件夹'); }
    this.walk(root, '');
  }
  private walk(root: string, prefix: string): void {
    for (const name of fs.listFileSync(`${root}/${prefix}`).sort()) {
      const relative = prefix + name;
      if (!validFolderPath(relative) || this.entries.length >= 100000) { throw new Error('文件夹层级、路径或条目数超过限制'); }
      const stat = fs.lstatSync(`${root}/${relative}`);
      if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) { throw new Error('不支持符号链接或特殊文件'); }
      const entry = new FolderEntry(); entry.path = relative; entry.directory = stat.isDirectory();
      entry.size = entry.directory ? 0 : stat.size;
      this.bytes += entry.size;
      if (!Number.isSafeInteger(this.bytes) || entry.size < 0) { throw new Error('文件夹过大'); }
      this.entries.push(entry);
      if (entry.directory) { this.walk(root, relative + '/'); }
    }
  }
}
export function removeTree(path: string): void {
  const stat = fs.lstatSync(path);
  if (stat.isDirectory() && !stat.isSymbolicLink()) {
    for (const name of fs.listFileSync(path)) { removeTree(`${path}/${name}`); }
    fs.rmdirSync(path);
  } else { fs.unlinkSync(path); }
}
