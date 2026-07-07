// Fixture: all functions are called
export function greetUser(name: string): string {
  return `Hello, ${name}`;
}

export const formatDate = (date: Date): string => {
  return date.toISOString();
};

// These functions are called below
const result1 = greetUser("World");
const result2 = formatDate(new Date());
console.log(result1, result2);
