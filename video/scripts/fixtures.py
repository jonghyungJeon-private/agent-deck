from pathlib import Path

def prepare(S, V, call):
    (S/'home/.zshenv').write_text('export PATH="'+str(S/'bin')+':/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"\nPROMPT="%F{magenta}demo%f %1~ ❯ "\n')
    for name in ['claude','codex']:
        path=S/'bin'/name
        path.write_text('#!/bin/sh\nexec /usr/bin/python3 "'+str(V/'scripts/fake-agent.py')+'" "$@"\n')
        path.chmod(0o755)
    # gh가 앱의 업데이트 확인에서도 실제 계정에 접근하지 않게 한다.
    (S/'bin/gh').write_text('#!/bin/sh\nexit 1\n'); (S/'bin/gh').chmod(0o755)
    for name in ['shop-api','shop-web','shop-docs']:
        repo=S/'demo'/name
        if (repo/'.git').exists(): continue
        (repo/'src').mkdir(parents=True,exist_ok=True)
        (repo/'README.md').write_text('# Shop API\n\n결제 서비스를 위한 작은 API입니다.\n\n## 변경 사항\n\n- 결제 검증 로직 분리\n- 중복 결제 방지\n- 쿠폰 경계값 테스트 추가\n\n## 검증\n\n```bash\nnpm test\n```\n\n| 항목 | 결과 |\n| --- | --- |\n| 결제 API | 통과 |\n| 쿠폰 정책 | 검토 중 |\n')
        (repo/'.gitignore').write_text('node_modules/\n.env\n')
        (repo/'src/payments.ts').write_text('// 결제 금액을 검증하고 승인 요청을 만듭니다.\nexport type Payment = {\n  orderId: string;\n  amount: number;\n  coupon?: string;\n};\n\nexport function validatePayment(payment: Payment): boolean {\n  return payment.amount > 0 && payment.orderId.length > 0;\n}\n\nexport function createPayment(payment: Payment) {\n  if (!validatePayment(payment)) {\n    throw new Error("결제 정보를 확인해 주세요");\n  }\n  return { ...payment, status: "approved" };\n}\n')
        (repo/'src/routes.ts').write_text('import { createPayment } from "./payments";\n\nexport function checkout(orderId: string, amount: number) {\n  return createPayment({ orderId, amount });\n}\n')
        call(['/usr/bin/git','-C',repo,'init','-b','main'])
        call(['/usr/bin/git','-C',repo,'add','.'])
        call(['/usr/bin/git','-C',repo,'-c','user.name=Demo','-c','user.email=demo@example.invalid','commit','-m','Fictional demo baseline'])
    api=S/'demo/shop-api'
    if not (S/'demo/shop-api-feature-coupon').exists():
        call(['/usr/bin/git','-C',api,'worktree','add','-b','feature/coupon',S/'demo/shop-api-feature-coupon'])
    with (api/'src/payments.ts').open('a') as f: f.write('\n// 다음 단계: 쿠폰 적용 후 금액을 검증합니다.\n')
    (api/'src/coupon.ts').write_text('export const COUPON_LIMIT = 10000;\n')
    call(['/usr/bin/git','-C',api,'add','src/coupon.ts'])
    (api/'src/payments.spec.ts').write_text('// 결제 경계값 테스트\nconst cases = [0, 1, 10000];\n')
    return S/'demo/shop-api'
