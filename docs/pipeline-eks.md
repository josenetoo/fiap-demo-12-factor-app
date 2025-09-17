# Pipeline: GitHub Actions + Argo CD + EKS (12‑Factor)

Este guia descreve o fluxo GitHub Actions → Docker Hub → Argo CD → EKS para implantar o app Node.js 12‑Factor deste repositório, com Helm e GitOps.

## Arquitetura
```mermaid
flowchart LR
  Dev[Git push] --> GH[GitHub]
  GH -->|Actions CI build/push| DH[(Docker Hub)]
  ACD[Argo CD on EKS] -->|sync manifests| EKS[(EKS cluster)]
  DH -->|pull| AppPod[Pod Express]
  User -->|HTTP 80| NLB[(AWS NLB)] --> SVC[Service LB] --> AppPod
  EKS -->|Probes /healthz| AppPod
  AppPod -->|stdout| Logs[kubectl logs]
```

## Pré‑requisitos
- Repositório GitHub com este código
- Conta no Docker Hub
- macOS com ferramentas:
  - `awscli` v2, `kubectl`, `helm`
- Credenciais AWS válidas (perfil, ex.: `fiapaws`) com acesso ao Learner Lab nas regiões `us-east-1` ou `us-west-2`

## 1) Preparar o repositório
- Ajustar registry (Docker Hub):
  - Editar `helm/demo-12-factor-app/values.yaml` e definir `image.repository: docker.io/<SEU_USUARIO>/demo-12-factor-app`
- Ajustar Git repo na Application do Argo CD:
  - Editar `argocd/application.yaml` e definir `spec.source.repoURL: https://github.com/<SEU_USUARIO>/demo-12-factor-app.git`

## 2) Provisionar o cluster EKS (CloudFormation)
O repositório já traz templates em `cloudformation/` e scripts de automação.

1. Crie um arquivo de variáveis (ou use o exemplo `env/cfn.env.example`):
```bash
cp env/cfn.env.example env/cfn.fiapaws
```
Edite `env/cfn.fiapaws` e ajuste:
```dotenv
AWS_REGION=us-east-1
AWS_PROFILE=fiapaws              # seu profile local
CLUSTER_NAME=demo-12-factor-eks

# Caso o Lab só disponibilize "LabRole", use para ambos (pode haver limites de IAM no Lab):
CLUSTER_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/LabRole
NODE_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/LabRole
```

2. Provisionar com o script (instala Argo CD automaticamente):
```bash
chmod +x scripts/deploy-cfn.sh scripts/destroy-cfn.sh
ENV_FILE=env/cfn.fiapaws scripts/deploy-cfn.sh
```

3. Verificação
```bash
kubectl get nodes
kubectl -n argocd get pods
```

## 3) Argo CD (instalado pelo script)
O `scripts/deploy-cfn.sh` instala o Argo CD. Para acessar a UI (opcional):
```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
# Senha inicial:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Você pode definir a senha do admin durante o provisionamento, passando `ARGOCD_ADMIN_PASSWORD` ao script:
```bash
ENV_FILE=env/cfn.fiapaws ARGOCD_ADMIN_PASSWORD='Fiap@2025!' scripts/deploy-cfn.sh
```
Se o `argocd` CLI não estiver instalado, o script tenta atualizar a senha via `htpasswd` (bcrypt) como fallback.

## 4) Passo manual: criar sua Application no Argo CD
Você pode criar via UI do Argo CD (Create Application) ou aplicar um YAML. Exemplo de YAML mínimo (ajuste o `repoURL` para o seu GitHub):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-12-factor-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<SEU_USUARIO>/demo-12-factor-app.git
    targetRevision: main
    path: helm/demo-12-factor-app
    helm:
      releaseName: demo-12-factor-app
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-12-factor-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```
Aplicar:
```bash
kubectl apply -f argocd/your-app.yaml   # ou cole o YAML acima em um arquivo e aplique
kubectl -n argocd get applications
```

## 5) Configurar o CI no GitHub (Docker Hub)
No repositório do GitHub, crie os Secrets:
- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN` (Access Token do Docker Hub)

O workflow `.github/workflows/ci.yaml` faz:
- Login no Docker Hub
- Build e push da imagem
- Atualiza `helm/demo-12-factor-app/values.yaml` com `image.tag=sha-<commit>`
- Commit e push do `values.yaml` atualizado (dispara o Argo CD)

## 6) Primeiro deploy end‑to‑end
Faça um commit na branch `main` (com os ajustes de `repoURL` e `image.repository`). O fluxo será:
1. GitHub Actions builda e publica a imagem
2. Atualiza `values.yaml` com `sha-<commit>`
3. Argo CD detecta a mudança e sincroniza o EKS

## 7) Validar a aplicação
O chart já expõe o Service como `type: LoadBalancer` com NLB. Aguarde o `EXTERNAL-IP`/hostname:
```bash
kubectl -n demo-12-factor-app get svc
# após o hostname aparecer:
curl http://<EXTERNAL-HOSTNAME>/healthz
```

## 8) Operação diária (12‑Factor na prática)
- Config (12‑Factor: Config): alterar `env:`/`secret:` em `values.yaml` → commit → Argo CD aplica sem rebuild
- Concurrency: ajustar `replicaCount` → commit → Argo CD aplica
- Logs (stdout): `kubectl logs -f deployment/demo-12-factor-app -n demo-12-factor-app`
- Saúde: probes usando `GET /healthz`

## 9) Acesso externo (NLB por Service LoadBalancer)
- O Service já cria um NLB automaticamente. Sem Ingress, sem ALB neste momento.
- Quando quiser evoluir para ALB (camada 7), instale o AWS Load Balancer Controller e crie um Ingress (futuro).

## 10) Futuro: Banco e Admin Processes
- Não usamos banco nesta demo. Quando quiser, adicione Postgres e referências por `DATABASE_URL`.
- Admin processes (migrations) não estão incluídos neste starter; adicione um Job específico quando necessário.

## Troubleshooting
- CI falha no Docker Hub:
  - Verificar Secrets `DOCKERHUB_USERNAME` e `DOCKERHUB_TOKEN`
- Argo CD não sincroniza:
  - `kubectl -n argocd get applications`
  - `kubectl -n argocd logs deploy/argocd-repo-server`
- Pod com erro:
  - `kubectl -n demo-12-factor-app describe pod <pod>` (ver env/probes)
- Sem acesso externo:
  - Aguarde o NLB (Service `EXTERNAL-IP`) propagar; em seguida use o hostname do Service

## Checklist
- [ ] `helm/demo-12-factor-app/values.yaml` com `image.repository` do seu Docker Hub
- [ ] Secrets GitHub: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`
- [ ] Cluster criado via `scripts/deploy-cfn.sh` e `kubectl get nodes`
- [ ] Argo CD instalado (via script) e sua Application criada manualmente
- [ ] Pipeline gerando `image.tag=sha-<commit>` e Argo CD sincronizando
- [ ] `curl /healthz` responde OK no hostname do NLB

## Fontes Verificadas
- Argo CD (Application): https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- Kubernetes (Deployments/Probes/ConfigMaps/Secrets): https://kubernetes.io/docs/
- Helm (Charts): https://helm.sh/docs/topics/charts/
- GitHub Actions (Docker build‑push): https://github.com/docker/build-push-action
- Docker Hub Access Tokens: https://docs.docker.com/security/for-developers/access-tokens/
- AWS EKS: https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html
- AWS Load Balancer Controller: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/
