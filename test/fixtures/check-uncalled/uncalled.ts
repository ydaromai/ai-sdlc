// Fixture: defines functions that are never called anywhere
export function unusedHelper(x: number): number {
  return x * 2;
}

export const deadCodeFunction = (msg: string): void => {
  console.log(msg);
};

export async function neverInvoked(): Promise<void> {
  await Promise.resolve();
}
