import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

// 书稿的单一源真在仓库根 ../book/，站点直接引用，避免两份副本漂移
const book = defineCollection({
  loader: glob({ base: "../book", pattern: "*.md" }),
  schema: z.object({
    title: z.string(),
    description: z.string().default(""),
    date: z.string().default(""),
    order: z.number().default(999),
  }),
});

export const collections = { book };
