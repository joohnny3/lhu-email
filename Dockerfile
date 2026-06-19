FROM mcr.microsoft.com/playwright:v1.60.0-jammy

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

ENV NODE_ENV=production
ENV TZ=Asia/Taipei

CMD ["npm", "run", "smoke"]
